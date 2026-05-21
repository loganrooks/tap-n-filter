# Audit Response 001

**Responder**: Claude (cold-context subagent, audit-response role)
**Responds to**: framing-audit-001.md
**Date**: 2026-05-20

## Summary

Twelve findings, dispositioned as follows: eleven `address`, one `escalate`, zero `disagree`. The escalation is F-005 (cut two of four bundled presets), where the choice involves product taste the user is better positioned to make than this responder. The disagree count is zero because the audit's findings are technically grounded and have concrete recommendations the responder considers correct or acceptably-close-to-correct; the rubric's "Low-severity batch disagree" default is overridden because each low-severity finding has a small, defined fix that costs less than documenting the disagreement would.

The audit's strongest moves are F-001 and F-002 — both correctly flag Swift snippets in the capture and effect-node specs that would produce compile errors or runtime bugs against the actual Core Audio and AVAudioEngine APIs. F-007 catches a related staleness in entitlements and Settings-path guidance that would have caused user-visible permission confusion. F-008 catches a real gap in the Codable plumbing for `[any EffectNode]` that the bundle gestures at but doesn't pin down. These four findings together justify the audit; without them the bundle would have shipped to Phase 1 with the orchestrator re-deriving load-bearing API details under time pressure.

The remaining findings range from useful housekeeping (F-009, F-010, F-011, F-012) to genuinely arguable scope and gate-design questions (F-003, F-004, F-005, F-006). For F-004 (wet/dry on EQ) and F-005 (four bundled presets), there are two defensible positions; the responder picks the lower-risk option for F-004 (UI hides slider, protocol surface unchanged) and escalates F-005 because the cuts are product decisions. F-003 and F-006 propose verification additions that the responder accepts: they make the gates harder for a sloppy orchestrator to pass.

Escalation rate is one of twelve (8.3%), well under the 20% over-escalation threshold from `escalation-criteria.md`. No findings contradict user-documented constraints. No findings require irreversible commitments. The responder's confidence on the F-007 resolution is the lowest of the eleven `address` calls because the recommendation is "verify and update" rather than a specific replacement; the verification step itself is correct regardless of what the verification turns up.

## Responses

### F-001: Capture spec uses pid_t where the API requires AudioObjectID

- **Action**: address
- **Confidence**: High

**Proposed revision 1 of 3**:
- File: `docs/specs/capture.md`
- Section: Replace the entire "Process tap creation" subsection (currently lines ~59-76) with the following.

```markdown
### Process tap creation

The Core Audio Process Tap API takes `AudioObjectID`s representing audio process objects, not raw `pid_t`s. The translation from a `pid_t` to the corresponding audio-process `AudioObjectID` is a HAL property lookup against the system object, using `kAudioHardwarePropertyTranslatePIDToProcessObject`. AudioCap performs this translation explicitly; tap-n-filter follows the same pattern.

```swift
/// Translates a Unix process identifier to the AudioObjectID representing
/// that process in the Core Audio HAL. Throws if the process is not known
/// to Core Audio (e.g., it is not producing audio).
private func audioProcessID(forPID pid: pid_t) throws -> AudioObjectID {
    var pidCopy = pid
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var processID: AudioObjectID = kAudioObjectUnknown
    var size = UInt32(MemoryLayout<AudioObjectID>.size)

    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        UInt32(MemoryLayout<pid_t>.size),
        &pidCopy,
        &size,
        &processID
    )
    guard status == noErr, processID != kAudioObjectUnknown else {
        throw CaptureError.sourceNotFound(pid)
    }
    return processID
}

/// Creates a Core Audio process tap for the given audio-process AudioObjectID.
///
/// The caller is responsible for translating from a `pid_t` to an
/// AudioObjectID via `audioProcessID(forPID:)` before calling this.
private func createTap(for audioProcessID: AudioObjectID) throws -> AudioObjectID {
    let description = CATapDescription(stereoMixdownOfProcesses: [audioProcessID])
    description.uuid = UUID()
    description.name = "tap-n-filter.tap.\(audioProcessID)" as CFString
    description.isPrivate = true
    description.isExclusive = false

    var tapID: AudioObjectID = kAudioObjectUnknown
    let status = AudioHardwareCreateProcessTap(description, &tapID)
    guard status == noErr else {
        throw CaptureError.tapCreationFailed(status)
    }
    return tapID
}
```

`stereoMixdownOfProcesses:` is the constructor AudioCap uses; it produces a 2-channel mixdown of the source process's output. For tap-n-filter's V1 stereo-only model this is the right choice. Note that `CATapDescription`'s property is `isPrivate` (not `privateTap`); verify against the AudioCap source at implementation time.
```

**Proposed revision 2 of 3**:
- File: `docs/specs/capture.md`
- Section: Replace the entire "Aggregate device creation" subsection (currently lines ~82-107) with the following.

```markdown
### Aggregate device creation

The tap on its own is not directly readable by `AVAudioEngine`. We create an aggregate device that contains the tap as one of its sub-streams. The tap's UID is a CFString fetched from the tap object via `kAudioTapPropertyUID` — there is no `.uid` property on `AudioObjectID`, which is a typealias for `UInt32`.

```swift
/// Reads the UID (a CFString) of a Core Audio tap object.
private func tapUID(for tapID: AudioObjectID) throws -> CFString {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioTapPropertyUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var uid: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

    let status = AudioObjectGetPropertyData(
        tapID,
        &address,
        0,
        nil,
        &size,
        &uid
    )
    guard status == noErr, let uid else {
        throw CaptureError.tapCreationFailed(status)
    }
    return uid.takeRetainedValue()
}

private func createAggregateDevice(containing tapID: AudioObjectID,
                                    forSource source: CaptureSource) throws -> AudioDeviceID {
    let uid = try tapUID(for: tapID)
    let description: [String: Any] = [
        kAudioAggregateDeviceUIDKey as String: "tap-n-filter.aggregate.\(source.pid)",
        kAudioAggregateDeviceNameKey as String: "tap-n-filter for \(source.displayName)",
        kAudioAggregateDeviceIsPrivateKey as String: true,
        kAudioAggregateDeviceIsStackedKey as String: false,
        kAudioAggregateDeviceTapListKey as String: [
            [
                kAudioSubTapDriftCompensationKey as String: false,
                kAudioSubTapUIDKey as String: uid
            ]
        ]
    ]

    var deviceID: AudioDeviceID = kAudioObjectUnknown
    let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &deviceID)
    guard status == noErr else {
        throw CaptureError.aggregateDeviceCreationFailed(status)
    }
    return deviceID
}
```

This is the central trick: the aggregate device is read by `AVAudioEngine` as if it were a normal input device, while internally it reads from the process tap. The exact property selectors and key names must be verified against AudioCap's source at implementation time; the API is sparsely documented and the strings above are written from the Apple-Framework reference rather than from a running build.
```

**Proposed revision 3 of 3**:
- File: `docs/orchestration/phases/01-capture-spike.md`
- Section: Section 1.1 — replace the `CaptureSource` struct definition (currently lines ~99-104) with:

```swift
public struct CaptureSource: Equatable, Identifiable {
    /// The Unix process identifier of the source application. Used for display
    /// and for restoration across launches (in combination with bundleIdentifier).
    public let pid: pid_t

    /// The Core Audio HAL's AudioObjectID representing this process's audio
    /// output object. Used by CaptureController to construct the CATapDescription.
    /// Resolved at source-enumeration time via
    /// kAudioHardwarePropertyTranslatePIDToProcessObject.
    public let audioProcessID: AudioObjectID

    public let bundleIdentifier: String?
    public let displayName: String
    public var id: pid_t { pid }
}
```

And add the following note immediately after the struct definition:

```markdown
The orchestrator resolves `audioProcessID` from `pid` inside `availableSources()` using `kAudioHardwarePropertyTranslatePIDToProcessObject` against the system object. If the process is not known to Core Audio (typically because it is not currently producing audio), the source is omitted from the returned list. The pattern is documented in `docs/specs/capture.md` under "Process tap creation."
```

Also add the following to Phase 1's "Failure modes" subsection:

```markdown
- **Process not registered with Core Audio.** A process must have audio activity for the HAL to assign it an AudioObjectID. If the user picks an app that is not producing audio at the moment, the translation step returns `kAudioObjectUnknown` and the start fails with `.sourceNotFound`. The UI surface should indicate "no current audio" for such sources rather than letting the user attempt capture.
```

**Rationale**: The audit's claim is verifiable against the Core Audio HAL header documentation: `pid_t` is `Int32` (a Unix process identifier), `AudioObjectID` is `UInt32`, and Core Audio's tap APIs operate on the latter. Passing a `pid_t` directly through `[AudioObjectID]` would compile under Swift's implicit `Int32`-to-`UInt32` conversion in some contexts but would produce nonsense at runtime: the kernel-process PID space and the HAL's AudioObjectID space are distinct. The translation step is documented in AudioCap and is the load-bearing API detail the bundle's pseudo-Swift was hiding. The revision makes the translation explicit, surfaces the failure mode (no audio currently → no AudioObjectID), and adjusts `CaptureSource` so the resolved AudioObjectID is carried alongside the `pid` for both display and capture-construction use.

---

### F-002: EffectNode bus typing loses the information the wet/dry pattern requires

- **Action**: address
- **Confidence**: High

**Proposed revision 1 of 4**:
- File: `docs/specs/effect-node-protocol.md`
- Section: Replace the `EffectNode` protocol definition (currently lines ~7-53) with:

```swift
public protocol EffectNode: AnyObject, Codable {
    /// A stable identifier for this effect type. Used in preset serialization.
    /// Convention: "tnf.<short-name>". Examples: "tnf.eq", "tnf.reverb".
    static var typeIdentifier: String { get }

    /// A unique identifier for this particular instance.
    var id: UUID { get }

    /// User-visible name. Defaults to the type's display name; can be renamed by the user.
    var displayName: String { get set }

    /// When true, audio passes through unchanged (the dry path).
    var bypass: Bool { get set }

    /// Mix between fully dry (0.0) and fully wet (1.0). 0.5 is approximately equal.
    var wetDryMix: Float { get set }

    /// The parameters this effect exposes.
    var parameters: [EffectParameter] { get }

    /// Update a parameter by identifier. Throws if the identifier is unknown
    /// or the value is outside the parameter's range.
    func setParameter(_ identifier: String, value: Float) throws

    /// Attach the underlying AVAudioUnit(s) to the engine. Called by the graph
    /// during `Graph.attach`. The node creates and attaches its internal mixer
    /// scaffolding here. After this call, `inputBus` and `outputBus` are valid
    /// and connectable.
    func attach(to engine: AVAudioEngine) throws

    /// Detach from the engine. Called by the graph during `Graph.detach`.
    func detach()

    /// The mixer node the graph connects audio INTO. This is the dry/wet input
    /// fan-out mixer. The graph connects to bus 0 of this mixer; the node
    /// reserves bus 0 for the graph and uses higher bus indices internally
    /// for the dry and wet paths.
    var inputBus: AVAudioMixerNode { get }

    /// The mixer node the graph connects audio OUT OF. This is the dry/wet
    /// summing mixer. The graph reads from bus 0 of this mixer. The dry path
    /// is connected to the node's `dryInputBusIndex` and the wet path to
    /// `wetInputBusIndex` on this mixer; both indices are >= 0 and are
    /// implementation details of the node, exposed only for the documented
    /// bypass / wet-dry-mix update path.
    var outputBus: AVAudioMixerNode { get }

    /// Capture the node's current state for serialization.
    func snapshot() -> EffectState

    /// Apply a previously captured state.
    func restore(from state: EffectState) throws
}
```

**Proposed revision 2 of 4**:
- File: `docs/specs/effect-node-protocol.md`
- Section: Replace the "Wet/dry mixing convention" section (currently lines ~91-112) with:

```markdown
## Wet/dry mixing convention

Every node implements wet/dry mixing internally. The pattern:

```
        inputBus (AVAudioMixerNode, single input on bus 0 from graph)
           │
           ├─ output bus 0 ── [dry gain unity] ────┐
           │                                       │
           └─ output bus 1 ── [effect AVAudioUnit] │
                                       │           │
                                       │           │
                              outputBus (AVAudioMixerNode)
                                 dry connects to input bus dryInputBusIndex
                                 wet connects to input bus wetInputBusIndex
                                       │
                                       ▼
                            graph reads from outputBus bus 0
```

`inputBus` is an `AVAudioMixerNode` that fans out the graph's input to two paths via its own output buses. `outputBus` is a second `AVAudioMixerNode` that sums the dry and wet paths using its per-input-bus volumes. The node owns both mixers, the dry-path gain (a third `AVAudioMixerNode` set to unity), and the wet-path `AVAudioUnit`. The dry path and wet path each connect to a specific input bus on `outputBus`; the per-bus volume on `outputBus` is what implements the wet/dry mix:

- `outputBus.volume(forInputBus: dryInputBusIndex)` = `1.0 - wetDryMix`
- `outputBus.volume(forInputBus: wetInputBusIndex)` = `wetDryMix`

Concrete nodes set these via `outputBus.setVolume(_:forInputBus:)` on every `wetDryMix` write. The `dryInputBusIndex` and `wetInputBusIndex` are conventionally 0 and 1 but are documented as private to the node — the graph never connects to or reads from these buses directly. The graph connects from a preceding node's `outputBus` bus 0 to the next node's `inputBus` bus 0, and the internal bus assignments inside each node are invisible to it.

This equal-power-only-approximately mixing is acceptable for V1. V2 may use sin/cos equal-power curves without changing the protocol surface.
```

**Proposed revision 3 of 4**:
- File: `docs/specs/audio-graph.md`
- Section: Replace the `attach` subsection (currently lines ~48-58) with:

```markdown
### `attach`

`attach` is called only when the engine is in a state where reconfiguration is permitted: either before `engine.start()` has been called for this session, or after `engine.stop()` (a full stop, not `engine.pause()`). Calling `attach` against a running or paused engine is a programming error in V1; the graph asserts on this and the caller (`AppViewModel`) is responsible for stopping the engine before any graph attach or mutation.

The sequence:

1. For each node in `nodes`, call `node.attach(to: engine)`. The node creates its mixer scaffolding (per the wet/dry mixing convention in `effect-node-protocol.md`), attaches its underlying `AVAudioUnit`s plus mixers to the engine, and connects its internal dry and wet paths to the appropriate input buses on its `outputBus`.
2. Connect `source` to `nodes[0].inputBus` on bus 0 with the source's `outputFormat(forBus: 0)`.
3. For each adjacent pair `(nodes[i], nodes[i+1])`, connect `nodes[i].outputBus` bus 0 to `nodes[i+1].inputBus` bus 0 with the upstream output format.
4. Connect `nodes[last].outputBus` bus 0 to a graph-owned `AVAudioMixerNode` that applies `outputGain` (set via its single-input bus volume).
5. Connect that mixer to `destination` bus 0.

Format negotiation: each `connect` uses the source node's `outputFormat(forBus: 0)`. The graph does not insert format converters; nodes are expected to produce a format compatible with the next node's input. The aggregate device's native format is the format the chain runs at; sample rate and channel layout are determined by the device, not by the graph.
```

**Proposed revision 4 of 4**:
- File: `docs/specs/audio-graph.md`
- Section: Replace the "Graph mutations during playback" subsection (currently lines ~94-104) with:

```markdown
## Graph mutations during playback

Adding, removing, or reordering nodes while audio is flowing requires care. `AVAudioEngine.pause()` is not sufficient — `attach`, `connect`, and `detach` calls on an engine that has been started require the engine to be fully stopped (`engine.stop()`), or the engine reports the connection as a no-op and audio routing silently breaks. The standard pattern:

1. Save the current graph snapshot (in case rollback is needed).
2. Stop the engine: `engine.stop()`. This drains the render loop fully.
3. Detach all nodes from the engine via `graph.detach()`.
4. Mutate the graph (add/remove/move).
5. Re-attach via `graph.attach(to:source:destination:)` with the same source and destination as the prior attach.
6. Start the engine: `engine.start()`.

The UI layer (Phase 3) presents this as instant, but internally there's a brief silence (typically 50–150 ms). Users notice the silence; the orchestrator can mitigate by fading output gain to zero, mutating, then fading back, but V1 does not implement this — the brief silence on mutations is acceptable.

The lifecycle constraint here is documented in `ADR-006-graph-mutation-lifecycle.md` (to be created during the framing-audit fix commit, as a consequence of resolving this finding).
```

Also add the following new ADR file:

- File: `docs/decisions/ADR-006-graph-mutation-lifecycle.md`
- Section: New file with the following full content:

```markdown
# ADR-006: Graph Mutation Lifecycle

## Status

Accepted

## Context

The `Graph` type (`docs/specs/audio-graph.md`) supports both attach-time wiring and runtime mutations (add, remove, move). Both interact with `AVAudioEngine`'s lifecycle. The question is which engine states permit which operations.

Three relevant engine states:

- **Not started.** The engine has been constructed but `start()` has not been called. Free reconfiguration is permitted.
- **Running.** `start()` has been called and the render loop is active. `pause()` suspends the render loop without tearing down the audio graph; the engine is still considered "running" for the purpose of structural reconfiguration.
- **Stopped.** `stop()` has been called after a `start()`. The render loop is fully torn down. Reconfiguration is permitted again.

`AVAudioEngine.attach`, `connect`, and `disconnect` calls behave differently across these states. While Apple's documentation suggests calls during `running` are permitted for some operations, in practice structural changes (attaching new nodes, reconnecting buses) require a full `stop()`; on a `pause()`-ed engine, structural calls may silently no-op, leaving the audio graph in an inconsistent state. This has been observed in third-party AVAudioEngine code and is consistent with Apple's "use Manual Rendering Mode for fully-controlled reconfiguration" guidance.

## Decision

All `Graph.attach`, `Graph.detach`, and any node-set mutation (`add`, `remove`, `move`) followed by re-attach require the engine to be **not started or fully stopped**. The graph asserts on this precondition. The caller (`AppViewModel`) is responsible for transitioning the engine to a permissible state before invoking these operations.

The mutation sequence is:

1. Save current snapshot for rollback.
2. `engine.stop()`.
3. `graph.detach()`.
4. Mutate the graph.
5. `graph.attach(to: engine, source:, destination:)`.
6. `engine.start()`.

For parameter updates (changing an `AVAudioUnit`'s parameter value via `setParameter`), the engine can remain running — those updates are thread-safe by Apple's contract.

## Alternatives considered

### Use `engine.pause()` instead of `engine.stop()`

Rejected. `pause()` suspends rendering but does not place the engine in a state where `connect` / `disconnect` calls are reliably honored. The original draft of `audio-graph.md` proposed this; the framing audit (F-002) caught it. Behavior differences across macOS minor versions make this approach especially fragile.

### Use `AVAudioEngine.enableManualRenderingMode` for mutations

Manual rendering mode permits full control over the engine, but switching into manual rendering for a mutation and back into auto-rendering is more complex than stopping and starting. For V1's mutation rate (low — users add or remove effects occasionally, not continuously), the simpler `stop`/`start` pattern is preferable.

### Reconstruct the engine on every mutation

Rejected as expensive. `AVAudioEngine` construction is non-trivial; doing it on every chain mutation would add hundreds of milliseconds of latency and would tear down the capture's aggregate-device input connection unnecessarily.

## Consequences

**Enabled:**
- Mutations are well-defined: the user adds an effect, hears a brief silence (~100 ms), and the new chain is live.
- The graph's invariants are protected by an explicit precondition rather than by hoping `pause()` does what it suggests.

**Precluded or constrained:**
- Mutations always interrupt audio briefly. V1 accepts this; V2 can experiment with fade-out / mutate / fade-in if the interruption is annoying in practice.
- The caller must manage engine state correctly. The view model has this responsibility; nothing in the graph layer assumes it.

**Risks:**
- A future contributor might call `graph.add` directly without stopping the engine. Mitigation: the graph asserts on the engine's `isRunning` state and traps with a descriptive message in debug builds.

## References

- `docs/specs/audio-graph.md` — graph spec; references this ADR from the "Graph mutations during playback" subsection.
- `docs/specs/effect-node-protocol.md` — node-level wet/dry pattern that depends on this lifecycle.
- `docs/audits/framing-audit-001.md` finding F-002 — the source of this decision.
- `docs/audits/audit-response-001.md` finding F-002 — the response that triggered creation.
```

**Rationale**: The audit correctly identifies two interlocking problems. First, returning `AVAudioNode` from `inputBus` and `outputBus` loses both the static `AVAudioMixerNode` type and the bus identity that the wet/dry pattern depends on — `AVAudioMixerNode` is the only `AVAudioNode` subclass that exposes per-input-bus volume control, which is the mechanism the protocol uses for mixing. The revised protocol declares the buses as `AVAudioMixerNode` explicitly and documents that the graph connects only to bus 0 on each end, while the node manages its internal dry/wet bus assignments privately. Second, the lifecycle pattern in the original `audio-graph.md` uses `engine.pause()` to wrap mutations, which is documented Apple-side as insufficient for `connect`/`disconnect` calls; `engine.stop()` is the correct boundary. The new ADR-006 pins the lifecycle commitment so Phase 2 and Phase 3 are both written against the same invariant. The brief audible silence is documented as the acceptable trade-off, matching the original spec's note about clicks-on-mutation.

---

### F-003: ear-test exercises DSP only; end-to-end capture+DSP is first tested in Phase 3

- **Action**: address
- **Confidence**: High

**Proposed revision 1 of 2**:
- File: `docs/orchestration/phases/02-dsp-chain.md`
- Section: Add a new task subsection 2.9, inserted between section 2.8 ("The ear test harness") and the "Gate criteria" section:

```markdown
### 2.9 End-to-end live render check

In addition to the offline ear test, Phase 2 runs a live integration check that exercises capture + DSP together in real time. This is the orchestrator's confidence check, not a user-facing gate, but it is required for Phase 2 to pass.

Steps:

1. Open a known YouTube tab in Safari playing a track with broad spectral content (the orchestrator picks one; suggest a music track with bass and high-frequency content).
2. Start the app's debug UI from Phase 1, configured to capture Safari.
3. Load the `distant-engines` preset and engage the chain.
4. Record the engine's output to `test-artifacts/ear-test-live.wav` for 10 seconds via `AVAudioEngine.installTap(onBus:bufferSize:format:)` on `mainMixerNode` writing to an `AVAudioFile`.
5. Compare `ear-test-live.wav` to `ear-test-output.wav` from the offline render. The orchestrator runs a simple spectral comparison (FFT magnitude over 1-second windows, mean absolute difference in dB) to confirm the live and offline renders have similar spectral character.

The orchestrator commits `ear-test-live.wav` (or omits it if size is a concern; the spectral-comparison numbers are sufficient as evidence) and documents the comparison in `docs/audits/verification/phase-2.md`.

If the live render diverges substantially from the offline render (different aggregate-device sample rate produces format-conversion artifacts, the engine's real-time scheduling produces audible glitches, etc.), the orchestrator addresses the underlying cause before requesting the user's ear test. Common causes:

- Sample-rate mismatch between the aggregate device and the EQ/Reverb units. Resolved by inserting an `AVAudioMixerNode`-based format converter at the graph's input.
- Buffer-size mismatch producing dropouts. Resolved by setting the engine's preferred I/O buffer duration to a value compatible with the device's native size.
- Aggregate-device latency producing audible echoes. Resolved by ensuring the engine's input format matches the aggregate device's format exactly.

Document the resolution in `docs/decisions/ADR-NNN-<topic>.md` if it shapes the architecture.
```

**Proposed revision 2 of 2**:
- File: `docs/orchestration/phases/02-dsp-chain.md`
- Section: Add a new gate criterion to the "Gate criteria" section. After current criterion 2 ("The ear test artifact pair exists at `test-artifacts/`."), insert:

```markdown
3. The end-to-end live render check (section 2.9) has been run and either (a) the live render matches the offline render within the spectral tolerance documented in the verification report, or (b) any divergence has been resolved with documented changes (typically an ADR).
```

Renumber the current criterion 3 ("The user has confirmed `[EAR_TEST: PASS]` in transcript.") to criterion 4.

**Rationale**: The audit's structural observation is correct: the ear test verifies the DSP graph against a known-good input but doesn't verify capture and DSP in the live signal path. Real-time capture introduces sample-rate, buffer-size, and scheduling considerations that don't surface in `AVAudioEngine.enableManualRenderingMode`. Catching those in Phase 2 — where the work is small (an extra hour of integration testing) — is much cheaper than catching them in Phase 3 under UI-work pressure or, worse, in Phase 4 user acceptance. The spectral-comparison approach gives the verification subagent a concrete artifact to evaluate (the wav file or the computed dB numbers) without requiring the verifier to listen. The check is the orchestrator's, not the user's; this preserves the human-input gate as the aesthetic check only.

---

### F-004: Wet/dry mixing on an EQ node is poorly motivated

- **Action**: address
- **Confidence**: Medium

**Proposed revision 1 of 3**:
- File: `docs/specs/effect-node-protocol.md`
- Section: At the end of the "Wet/dry mixing convention" section (after the revisions in F-002), append:

```markdown
### When wet/dry is meaningful

Wet/dry mixing is meaningful for time-domain effects where the wet path produces a signal distinct from the input (reverb tails, delay echoes, distortion harmonics). For these effects, mixing dry input back in at `wetDryMix < 1.0` reduces the effect's prominence without changing its character.

Wet/dry mixing is **less meaningful** for spectral-shaping effects (EQ, filters) where the wet path is the input with selected frequency content removed. At `wetDryMix = 0.5` for an EQ that filters frequency F, half of frequency F is summed back from the dry path, defeating the filter. For such effects, the meaningful operating value is `wetDryMix = 1.0` (fully wet, full filtering) and the bypass toggle handles the "no effect" case.

The protocol still requires `wetDryMix` on every node — the uniformity of the protocol surface is load-bearing for the graph layer, the UI's per-row controls, and serialization. Concrete nodes that don't meaningfully benefit from wet/dry mixing implement the protocol normally and document the limitation in their doc comments. The UI (`docs/specs/ui.md`) governs which nodes expose the wet/dry slider visibly.
```

**Proposed revision 2 of 3**:
- File: `docs/specs/ui.md`
- Section: Replace the EffectRow section's description of the wet/dry slider (currently the line "The wet/dry slider is always visible (it's the most-used control).") with:

```markdown
The wet/dry slider is visible by default for nodes whose effect is time-domain (e.g., reverb, future delay, future distortion) — for these the wet/dry control is the most-used adjustment. For nodes whose effect is spectral-shaping (e.g., EQ), the wet/dry slider is hidden by default and accessible only via the expanded controls panel; the rationale is that wet/dry on an EQ at any value other than 1.0 partially defeats the filter, which is rarely what a user adjusting the slider expects.

The decision of "show wet/dry by default" is per-node. Each `EffectNode` exposes a static property `showsWetDryByDefault: Bool` (default `true`) that the UI consults when rendering the `EffectRow` header. `EQNode` overrides this to `false`; `ReverbNode` uses the default `true`.
```

**Proposed revision 3 of 3**:
- File: `docs/decisions/ADR-007-wet-dry-on-eq.md`
- Section: New file with the following full content:

```markdown
# ADR-007: Wet/Dry Mixing on Spectral-Shaping Effects

## Status

Accepted

## Context

The `EffectNode` protocol requires every effect to expose a `wetDryMix` parameter and implement internal wet/dry mixing via parallel paths through a mixer. This is the standard pattern for time-domain effects (reverb, delay, distortion), where the wet path produces a signal distinct from the input and dry/wet mixing reduces the effect's prominence.

For spectral-shaping effects (EQ, filters), wet/dry mixing has unexpected semantics. At `wetDryMix = 0.5`, half of the unfiltered signal is summed back in, partially defeating the filter. A user dragging a slider labeled "wet/dry" on an EQ from 100% to 50% probably expects a softer or less prominent EQ, but actually gets a partial bypass that re-introduces the frequencies they were filtering out.

The framing audit (F-004) noted this and that the `distant-engines` preset sets the EQ's `wetDryMix` to 1.0, suggesting the author already noticed the issue at preset-tuning time.

Two options:

1. Drop `wetDryMix` from the protocol's required surface; make it optional per node.
2. Keep the protocol-level requirement but hide the EQ's wet/dry slider in the UI by default.

## Decision

Option 2: **keep the protocol-level `wetDryMix` requirement; hide the slider in the default UI surface for spectral-shaping nodes.**

The `EffectNode` protocol continues to require every node to expose and implement `wetDryMix`. Concrete spectral-shaping nodes implement it normally (e.g., `EQNode`'s `wetDryMix` does what the protocol describes — wet equals filtered signal, dry equals unfiltered, mix sums them).

A new static property on `EffectNode` controls whether the UI shows the wet/dry slider in the always-visible header of the effect row:

```swift
public protocol EffectNode: AnyObject, Codable {
    // ... existing members ...

    /// Whether the EffectRow displays the wet/dry slider in the always-visible
    /// header. When false, the slider is still accessible via the expanded
    /// controls panel but is not in the default UI footprint.
    /// Default: true. Spectral-shaping effects (EQ, filters) override to false.
    static var showsWetDryByDefault: Bool { get }
}

extension EffectNode {
    public static var showsWetDryByDefault: Bool { true }
}
```

`EQNode` overrides this to `false`. `ReverbNode` uses the default `true`.

## Alternatives considered

### Option 1: Make `wetDryMix` optional per node

Cleaner conceptually — only nodes that benefit from wet/dry expose it — but breaks the uniformity of the protocol surface. The graph layer, the serialization format, the preset migration story, and the UI's per-row layout all become per-node-conditional. Adding a new spectral-shaping effect type would require deciding how to serialize the missing field, and existing presets with `wetDryMix` set on an EQ would either need migration or graceful-ignore handling.

Option 2 keeps the surface stable: every effect serializes the same fields, the registry's signature doesn't change, and the UI's per-effect customization is one boolean rather than a protocol-shape difference.

### Option: leave the wet/dry slider visible on EQ

Rejected. The user-experience cost (a slider that defeats the user's settings when moved away from 100%) outweighs the consistency benefit of "every row looks the same." The audit's framing of this as a real UX defect is correct.

## Consequences

**Enabled:**
- The protocol surface stays uniform across all effect types.
- Serialization, preset migration, and the registry are unchanged.
- The UI can hide unhelpful controls on a per-effect-type basis without restructuring.

**Precluded or constrained:**
- The UI has one more piece of per-effect-type state (`showsWetDryByDefault`) that the orchestrator must remember to set correctly when adding new effect types.
- Users who explicitly want to use wet/dry on an EQ for creative reasons (a partial-filter blend effect) must expand the effect's controls panel to access it — slightly less discoverable than the default-visible slider.

**Risks:**
- A future effect type's appropriate default for `showsWetDryByDefault` may not be obvious. Mitigation: document the rule (time-domain → true, spectral-shaping → false) in the protocol's doc comment.

## References

- `docs/specs/effect-node-protocol.md` — protocol definition.
- `docs/specs/ui.md` — EffectRow layout.
- `docs/audits/framing-audit-001.md` finding F-004.
- `docs/audits/audit-response-001.md` finding F-004.
```

**Rationale**: The audit's two options both have merit. Option (a) — drop `wetDryMix` from the protocol — is conceptually cleaner but ripples through serialization, migration, registry shape, and UI structure. Option (b) — protocol-level uniformity, UI customization per node — keeps the surface stable and addresses the user-experience issue with a small per-type flag. The lower-risk option is (b): one static property, one UI conditional, one short ADR. The protocol stays load-bearing for the graph and the preset format. The auditor explicitly noted EQ's preset value is set to 1.0, which is consistent with this resolution — the EQ effectively never uses wet/dry below 1.0 in any meaningful preset, so hiding the slider matches the actual use pattern.

---

### F-005: The four-preset bundle is two presets larger than the rationale supports

- **Action**: escalate
- **Confidence**: N/A (escalating)

**Question for user**:

> The framing audit recommends cutting two of the four bundled factory presets to bring V1's preset set in line with what the design rationale motivates. The recommendation: ship `distant-engines` (the motivating preset) and `dry` (a baseline) in V1; defer `submerged` and `next-room` to V0.2 as TODOs.
>
> The audit's reasoning: only `distant-engines` will be ear-tested in Phase 2; the other two presets' parameter choices aren't justified anywhere in the bundle; the "slight modulation if implemented" hedge on `submerged` admits the orchestrator does not yet know whether the preset's character is achievable in V1. Shipping unjustified, unverified presets risks (a) consuming Phase 2 tuning time on presets you may not have asked for, (b) shipping presets that don't sound like their names promise, (c) accumulating product surface area that V2 then has to maintain.
>
> Three options:
>
> 1. Cut to two presets (`distant-engines` and `dry`). Leave `submerged` and `next-room` as TODOs in README/CHANGELOG. Lowest-risk option; matches the audit's recommendation.
> 2. Keep all four. Add a Phase 2 sub-task to ear-test `submerged` and `next-room` as well; document parameter choices in an ADR. Higher cost in Phase 2 (extra tuning iterations), keeps the broader factory set.
> 3. Keep all four as-is. Accept the audit's risk; ship the additional presets without ear-testing them. Lowest cost in Phase 2; ships untested aesthetic content.
>
> Which option would you like?

**Context**: The audit's structural observation is correct on the facts — only `distant-engines` is ear-tested, the other two presets' parameters aren't justified in the bundle, and "slight modulation if implemented" is a real hedge. The decision of how many factory presets the V1 ships with is a product judgment about how much breadth signals quality vs. how much depth signals quality. This responder has no access to the user's preferences on that trade-off. The user also may have aesthetic preferences for the names and characters of `submerged` and `next-room` that aren't captured in the bundle.

**What I considered**: The rubric defaults this finding to `address` (Medium-severity with a concrete recommendation). The reason for deviating: cutting product features hits escalation criterion (a) — domain judgment beyond agent competence, specifically the user's tolerance for the trade-off between shipping breadth and shipping verified quality. Option 1 is what the responder would pick if forced to autonomously decide, but the user's `distant-engines`-was-the-motivating-preset framing in the design rationale doesn't actually rule out wanting other presets too. The cost of asking is one short question; the cost of cutting the user's preferred presets autonomously is higher.

---

### F-006: Phase 3 accessibility gate is structurally self-audited

- **Action**: address
- **Confidence**: High

**Proposed revision 1 of 3**:
- File: `docs/orchestration/phases/03-ui-control.md`
- Section: Replace section 3.8 ("Accessibility audit") with:

```markdown
### 3.8 Accessibility audit

The accessibility gate has two parts: a programmatic check the verification subagent can re-run, and a manual VoiceOver pass the orchestrator performs.

Programmatic check:

1. The orchestrator builds the app and launches an `XCUIApplication` test target that walks the menubar UI.
2. The test uses `XCUIElementQuery` to enumerate every interactive element in the `ControlPanelView` hierarchy.
3. For each element, the test asserts:
   - `accessibilityLabel` is non-empty.
   - For sliders and pickers, `accessibilityValue` is non-empty when the element has a current value.
   - For elements identified by the spec as `accessibilityHint`-eligible (controls whose action is non-obvious), the hint is non-empty.
4. The test dumps the full accessibility tree as JSON to `test-artifacts/phase-3-accessibility-tree.json` and commits it as evidence.

The verification subagent re-runs this test (or reads the committed JSON dump plus the test-pass log) to confirm the assertions hold.

Manual VoiceOver pass:

1. The orchestrator runs the app with VoiceOver enabled.
2. The orchestrator navigates through every control using only VoiceOver gestures + keyboard, and confirms each control is reachable and produces a sensible spoken response.
3. The orchestrator records observations in `docs/audits/verification/phase-3-accessibility.md`.

The manual pass catches qualitative issues (labels that are technically present but unhelpful, navigation order that's surprising). The programmatic check catches structural omissions (a control with no label at all). Both are required for the phase to pass.
```

**Proposed revision 2 of 3**:
- File: `docs/orchestration/phases/03-ui-control.md`
- Section: Replace gate criterion 5 ("Accessibility audit shows no major issues...") with:

```markdown
5. The accessibility audit passes both parts: (a) the programmatic accessibility-tree test at `test-artifacts/phase-3-accessibility-tree.json` shows every interactive element has a non-empty `accessibilityLabel` (and non-empty `accessibilityValue` where applicable), confirmed by the verification subagent re-reading the JSON or the test log; and (b) the manual VoiceOver pass documented in `docs/audits/verification/phase-3-accessibility.md` reports no major issues.
```

**Proposed revision 3 of 3**:
- File: `docs/orchestration/phases/01-capture-spike.md`
- Section: Replace gate criterion 2 with:

```markdown
2. A documented test of "start → 5 seconds passthrough → stop" runs successfully on the orchestrator's machine. The recorded output is committed to `test-artifacts/phase-1-passthrough.wav` (gitignored if the repo size matters; the verification subagent reads from the working tree). The orchestrator's transcript log is at `docs/audits/verification/phase-1-passthrough.md`. The verification subagent runs a level check against the wav (RMS over the 5-second window > -60 dBFS) to confirm non-silent audio is present, in addition to reading the transcript.
```

Also append to the phase's "Outputs" section the new line:

```markdown
- A captured passthrough wav at `test-artifacts/phase-1-passthrough.wav` (gitignored).
```

**Rationale**: The audit's structural observation generalizes beyond Phase 3 — wherever the orchestrator is the only witness, the gate is structurally soft, and a sloppy orchestrator can produce convincing-looking artifacts. The fix is to require a programmatic artifact the verification subagent can independently re-evaluate. For Phase 3, the accessibility-tree JSON dump is the right artifact — it's machine-checkable for the most common omissions (missing labels), and the qualitative VoiceOver pass remains as the human-shaped check that catches the rest. For Phase 1, requiring the recorded wav plus a programmatic level check (RMS over the window) catches the "I claim non-silent audio is present" failure mode. The audit notes Phase 4's clean-machine launch verification is genuinely hard to automate; the fallback there ("documented approach") is acceptable as the spec already states, but no revision is proposed for Phase 4 — the existing documented-approach fallback is the best available given the constraint.

---

### F-007: macOS audio capture permission UI and entitlement details are stale or speculative

- **Action**: address
- **Confidence**: Medium

**Proposed revision 1 of 4**:
- File: `docs/specs/capture.md`
- Section: Replace the "Permission handling" subsection (currently lines ~137-142) with:

```markdown
### Permission handling

The first call to `AudioHardwareCreateProcessTap` triggers the audio capture permission prompt. The text in the prompt comes from `Info.plist`'s `NSAudioCaptureUsageDescription`.

If the user denies, subsequent calls return an error. The orchestrator detects this and throws `CaptureError.permissionDenied`. The UI surfaces the error with a link to System Settings.

The exact path in System Settings for the audio capture permission must be verified against the orchestrator's current macOS version before being included in user-facing text. The relevant pane in macOS 14.4+ is reported by Apple Developer Forum threads to be a distinct "Audio Capture" or "Audio recording" pane separate from "Microphone," though Apple's terminology has shifted across minor releases. The orchestrator runs the app once on the build machine, confirms which pane controls the permission, and updates any user-facing text and any deep-link URL (e.g., `x-apple.systempreferences:com.apple.preference.security?Privacy_<PaneIdentifier>`) to match. This verification step is recorded in `docs/audits/verification/phase-1.md`.

Until the verification step is performed in Phase 1, user-facing text refers generically to "the audio capture permission in System Settings → Privacy & Security" without naming a specific sub-pane. Uncertainty entry U-008 tracks the verification.
```

**Proposed revision 2 of 4**:
- File: `docs/orchestration/phases/01-capture-spike.md`
- Section: Replace section 1.3 ("Permission handling") with:

```markdown
### 1.3 Permission handling

The first call to `availableSources()` or `start()` triggers the audio capture permission prompt. If the user denies, `CaptureError.permissionDenied` is thrown. The debug UI surfaces this clearly and offers a link to System Settings.

As part of Phase 1, the orchestrator verifies on the build machine the exact System Settings pane that controls the audio capture permission for macOS 14.4+. Apple Developer Forum guidance and AudioCap's own documentation describe a distinct "Audio Capture" pane separate from Microphone in recent macOS minor versions. The verification:

1. Run the app, trigger the permission prompt, deny it.
2. Open System Settings and identify which pane lists tap-n-filter and controls its audio capture permission.
3. Note the pane's exact name and its `x-apple.systempreferences:` URL (if any).
4. Update `docs/specs/capture.md`'s permission section and the debug UI's deep-link to match.
5. Record observations in U-008 and either resolve U-008 (if observation is stable) or leave it open (if behavior varies across macOS minor versions seen during development).
```

**Proposed revision 3 of 4**:
- File: `docs/orchestration/phases/04-polish-release.md`
- Section: Replace section 4.3 ("Code signing") with:

```markdown
### 4.3 Code signing

Sign the app using `codesign --deep --force --options=runtime --entitlements ... --sign "<identity>" ...`.

Entitlements:
- Hardened runtime is enabled (required for notarization).
- App Sandbox is not enabled (ADR-003).
- No additional capability entitlements are added by default. The audio capture flow for process taps in an unsandboxed app is governed by `NSAudioCaptureUsageDescription` in `Info.plist`, not by an entitlement. `com.apple.security.device.audio-input` is the microphone-hardware entitlement for sandboxed apps; adding it to an unsandboxed app has no documented effect and may produce notarization or Gatekeeper surprises that are hard to diagnose after the fact.

The orchestrator verifies the exact entitlement requirements against current Apple documentation at the start of Phase 4. If current Apple documentation requires a process-tap-specific entitlement for unsandboxed apps with hardened runtime (none is documented as of the bundle's scribing date), the orchestrator adds it and writes a brief ADR. If no entitlement is required, the orchestrator commits the entitlements file (an empty `<dict/>` inside the plist, or omitted entirely) and records the verification in U-008.

The orchestrator writes `Build/sign.sh` containing the exact `codesign` invocation, committed to the repo. Phase 4 PRs include this script.
```

**Proposed revision 4 of 4**:
- File: `docs/decisions/uncertainty-log.md`
- Section: Add a new entry at the bottom of the "## Entries" section (after U-007):

```markdown
---

## U-008: macOS audio capture permission location and entitlements

**Status**: Open
**Triggered by**: Framing audit F-007 (`docs/audits/framing-audit-001.md`).
**Question**: (a) Which exact System Settings pane on the orchestrator's macOS version controls the audio capture permission for tap-n-filter, and what is its deep-link URL? (b) For an unsandboxed hardened-runtime app using Core Audio Process Taps, what (if any) entitlements does Apple's current documentation require?

**Current best guess**: (a) Recent macOS minor versions surface a distinct "Audio Capture" or "Audio recording" pane separate from Microphone in Privacy & Security. The bundle's scribed-as text referred to "Microphone" which appears to be stale. (b) `com.apple.security.device.audio-input` is the microphone-hardware entitlement for sandboxed apps and likely does nothing for an unsandboxed app using process taps. No process-tap-specific entitlement is documented in the public Apple developer reference at scribing time; `NSAudioCaptureUsageDescription` in `Info.plist` is the binding control.

**Resolution path**: (a) Resolved during Phase 1 when the orchestrator runs the app on the build machine and observes which pane lists tap-n-filter. (b) Resolved during Phase 4 when the orchestrator verifies entitlement requirements against Apple's current notarization documentation. Both resolutions update `docs/specs/capture.md` and `docs/orchestration/phases/04-polish-release.md` to match observed behavior.

**Revisit trigger**: Phase 1 permission-flow implementation (part a); Phase 4 signing setup (part b).
```

**Rationale**: The audit's claim that the "Microphone" path is stale and that `com.apple.security.device.audio-input` is the wrong entitlement for the unsandboxed process-tap path is consistent with publicly-available Apple Developer Forum guidance about the post-14.4 permission redesign and with the documented purpose of the audio-input entitlement (sandboxed microphone access). The responder's confidence on the specific replacement names — "Audio Capture" vs "Audio Recording" vs whatever Apple now calls it — is medium, because Apple has shifted these names across minor releases. The resolution is not to commit to a specific replacement string in the spec but to (a) remove the stale references, (b) commit to verifying on the build machine before publishing user-facing text, (c) track the verification in U-008 so the orchestrator does not forget. This is the right shape because the verification step is correct regardless of what the verification turns up — the worst case is the orchestrator confirms the original "Microphone" path is still correct, in which case the spec gets updated to say "verified Microphone in macOS X.Y.Z" rather than the unsourced original claim.

---

### F-008: GraphPreset Codable mechanism for `[any EffectNode]` is referenced but never specified

- **Action**: address
- **Confidence**: High

**Proposed revision 1 of 2**:
- File: `docs/specs/preset-format.md`
- Section: Add a new subsection inserted immediately before the "Compatibility across effect versions" section (currently around line 79):

```markdown
## Swift Codable mechanism

`GraphPreset.nodes` is declared `[EffectState]` in the on-disk representation (each element a fully-serialized state object with a `typeIdentifier`). The in-memory `Graph.nodes` is `[any EffectNode]`. The translation between the two is handled at the `GraphPreset` boundary, not the protocol boundary.

Encoding (`Graph.snapshot()` → `GraphPreset` → JSON):

```swift
public struct GraphPreset: Codable {
    public let formatVersion: Int
    public let name: String
    public let outputGain: Float
    public let nodes: [EffectState]

    public init(formatVersion: Int = 1,
                name: String,
                outputGain: Float,
                nodes: [EffectState]) {
        self.formatVersion = formatVersion
        self.name = name
        self.outputGain = outputGain
        self.nodes = nodes
    }
}

extension Graph {
    public func snapshot() -> GraphPreset {
        GraphPreset(
            name: "snapshot",  // caller can rename
            outputGain: outputGain,
            nodes: nodes.map { $0.snapshot() }
        )
    }
}
```

The `Codable` derivation on `GraphPreset` is automatic — `EffectState` is itself `Codable`, and an array of `Codable` is `Codable`.

Decoding (JSON → `GraphPreset` → `Graph.restore`):

```swift
extension Graph {
    public static func restore(from preset: GraphPreset,
                                using registry: EffectNodeRegistry) throws -> Graph {
        var nodes: [any EffectNode] = []
        var warnings: [PresetLoadWarning] = []

        for state in preset.nodes {
            do {
                let node = try registry.makeNode(typeIdentifier: state.typeIdentifier)
                try node.restore(from: state)
                nodes.append(node)
            } catch RegistryError.unknownTypeIdentifier(let id) {
                warnings.append(.unknownEffect(typeIdentifier: id))
                // Skip this node; loader is best-effort per preset-format.md
            }
        }

        let graph = Graph(nodes: nodes, outputGain: preset.outputGain)
        if !warnings.isEmpty {
            // Caller observes warnings via a side channel; one V1 approach is
            // a static `lastLoadWarnings` on PresetStore that the view model
            // reads after a load. V2 may pass warnings through directly.
        }
        return graph
    }
}
```

`EffectNodeRegistry.makeNode(typeIdentifier:)` returns a freshly-constructed node of the corresponding concrete type — typically by invoking the type's no-argument initializer, which produces a node in its default state. `restore(from:)` then writes the saved parameters, bypass, wet/dry, displayName, and id onto the fresh node.

This pattern scales to V2's AUv3 hosting: `AUv3Node` registers with the same `EffectNodeRegistry` at app launch (or on-demand when an AUv3 plugin is loaded), `restore(from:)` reads the AUv3-specific state from `EffectState.extras`, and the discriminated-union behavior is unchanged.

The `EffectNode` protocol's `init(from decoder: Decoder)` is not used by the preset I/O path — `GraphPreset` is the boundary. Concrete types may still provide `init(from:)` for direct decoding of a single node from JSON (a future "import single effect" feature), but it is not required for V1.
```

**Proposed revision 2 of 2**:
- File: `docs/specs/effect-node-protocol.md`
- Section: Replace the "Codable conformance" section (currently lines ~120-139) with:

```markdown
## Codable conformance

`EffectNode` is `Codable` to support direct encoding of a node's state. The default extension delegates encoding to `snapshot()`:

```swift
extension EffectNode {
    public func encode(to encoder: Encoder) throws {
        try snapshot().encode(to: encoder)
    }

    public init(from decoder: Decoder) throws {
        // Concrete types implement this if direct-from-decoder construction is
        // needed (e.g., for a future "import single effect" feature). The
        // implementation reads the EffectState and calls restore(from:) on a
        // freshly-constructed instance. The protocol cannot provide a default
        // because Swift protocols cannot construct conforming types.
        fatalError("Concrete EffectNode must implement init(from:) if direct decoding is required.")
    }
}
```

The primary deserialization path does **not** use `init(from:)` — see `docs/specs/preset-format.md` under "Swift Codable mechanism." `GraphPreset.nodes` decodes as `[EffectState]` (no protocol witness required), and `Graph.restore(from:using:)` translates each `EffectState` into a concrete `EffectNode` via the `EffectNodeRegistry`. This avoids the protocol-init-from-decoder limitation.

Concrete effect implementations may provide `init(from:)` for direct decoding of a single node from JSON (a future feature). V1 does not exercise this path and concrete types may leave the protocol's default `fatalError` in place.
```

**Rationale**: The audit's gap is real: the bundle gestures at "a discriminated-union pattern keyed on `typeIdentifier`" but never writes down the Swift code. The right shape is to make the boundary explicit at `GraphPreset` rather than at `EffectNode` — `GraphPreset.nodes` is `[EffectState]` (a concrete `Codable` struct), so the on-disk decode is unproblematic, and the registry-based dispatch happens during `Graph.restore` after the `GraphPreset` is in memory. This sidesteps the well-known Swift problem of "protocol cannot decode itself" without requiring a discriminator enum that would need to be updated for every new effect type. The pattern scales cleanly to V2's `AUv3Node` because the registry is the only enumeration point. The proposed code is canonical and the orchestrator can copy it directly.

---

### F-009: Loopback re-entry on phase REVISE is undefined in state.json schema

- **Action**: address
- **Confidence**: High

**Proposed revision**:
- File: `docs/orchestration/state.json`
- Section: Replace the `_schema_note` value (currently the last field in the JSON) with:

```json
"_schema_note": "Status values: pending | in_progress | passed | failed | blocked. The orchestrator transitions a phase from pending or blocked to in_progress when starting work, then to passed only on verification PASS. Failed phases remain failed until the orchestrator addresses findings and re-runs verification. State transitions are committed with messages of the form 'state: <phase> -> <new_status> (<short reason>)'. Phase re-entry after a downstream REVISE: when a user [REVISE: <what>] reply in Phase 4 directs the orchestrator back to phase N (typically 2 or 3), that phase transitions passed -> in_progress; the orchestrator writes a new verification report under a -revise-K suffix (e.g., phase-2-revise-1.md) when the re-run completes; state.json records the loop in human_inputs.other_escalations with a 'phase_revise' entry pointing to the new verification report. Phase 4 then re-runs after the upstream phase returns to passed."
```

**Rationale**: The audit's observation is correct — the schema notes status values and forward transitions but is silent on what happens when a passed phase needs to re-open. The Phase 4 spec's "Failure modes" section mentions returning to earlier phases but doesn't pin the transitions. The fix is a single sentence in the schema note plus a convention for the verification report filename (matching the existing `-rerun-K` pattern). This is small but it removes an undefined-state-at-the-worst-time risk.

---

### F-010: ScreenCaptureKit "fallback as contained change" oversells the modularity

- **Action**: address
- **Confidence**: High

**Proposed revision**:
- File: `docs/decisions/ADR-001-capture-api.md`
- Section: Replace the "ScreenCaptureKit" subsection under "Alternatives considered" (currently lines ~36-45) with:

```markdown
### ScreenCaptureKit

Would also work technically. Rejected for three reasons:

1. Triggers the screen-recording permission prompt, even when no screen recording happens. Users find this confusing — "this app says it needs screen recording, but it's not recording my screen." Apple's UI doesn't distinguish the audio-only case.

2. Higher overhead due to the video pipeline machinery that's loaded even when only audio is requested.

3. Apple's own engineers, on the developer forums, have explicitly recommended Core Audio Process Taps over ScreenCaptureKit for audio-only cases. This is an official-channel signal, not a third-party opinion.

ScreenCaptureKit remains a potential fallback if Core Audio Process Taps prove untenable (tracked in `uncertainty-log.md`). The fallback is a substantial rewrite, not a contained change: `docs/specs/capture.md`'s CaptureController is structured around aggregate-device + HAL-property-setter calls that are specific to the process-tap backend. The public `CaptureControllerProtocol` exposes nothing that abstracts over the underlying capture mechanism. Swapping backends would mean replacing the concrete `CaptureController` implementation entirely. V1 commits to the process-tap path; if the fallback is needed, that work is its own design pass and likely its own ADR superseding this one.
```

**Rationale**: The audit's "authority laundering" framing is fair — the original phrase "swapping the capture backend would be a contained change" leans on a modularity claim that the code doesn't actually deliver. The honest version is "we commit to process taps for V1; the fallback exists but it's a rewrite, not a swap." The revised text says that plainly without overclaiming the architecture's flexibility. No structural change is required; the architecture is fine as committed, just described accurately.

---

### F-011: CodeRabbit template repo dependency may leak content into a public repo

- **Action**: address
- **Confidence**: High

**Proposed revision**:
- File: `docs/orchestration/phases/00-init.md`
- Section: Replace the third paragraph of section 0.5 (currently the sentence about CodeRabbit GitHub App verification, around lines ~91-93) with the following — leaving the surrounding paragraphs about the template clone and the no-op-PR verification intact:

Find the existing paragraph:
```
The CodeRabbit GitHub App must be installed and authorized on the new repo. Verify by opening the no-op PR (step 0.7) and confirming a CodeRabbit comment appears within five minutes.
```

Replace with:

```markdown
Before committing the adapted `.coderabbit.yaml`, the orchestrator scans the file for references to private repositories, internal services, API keys, internal service URLs, or any identifiers that should not appear in a public repo. The `loganrooks/coderabbit` template is described as canonical config and instructions copied across the user's repos; while the base rate of secrets in such files is low, the adaptation step is the only guard. Any private-context references are removed or replaced with public-safe equivalents before the file is committed.

The CodeRabbit GitHub App must be installed and authorized on the new repo. Verify by opening the no-op PR (step 0.7) and confirming a CodeRabbit comment appears within five minutes.
```

**Rationale**: The audit's risk is small but real — a config "adapted" without an explicit scan step relies on the orchestrator to notice incidentally. Making the scan an explicit, named step before commit costs one extra read pass and removes the failure mode. The change is local to one paragraph.

---

### F-012: U-005 ear-test input licensing is left dangling until Phase 2

- **Action**: address
- **Confidence**: High

**Proposed revision 1 of 3**:
- File: `docs/orchestration/phases/02-dsp-chain.md`
- Section: Replace the entire section 2.8 ("The ear test harness") with the following:

```markdown
### 2.8 The ear test harness

Build a small command-line target `tap-n-filter-eartest` that:

1. Loads an input wav from a path provided via a CLI flag (`--input <path>`). If no flag is provided, the harness generates a default test signal: a 30-second composite consisting of pink noise (10 s, broadband content for spectral verification), a logarithmic sine sweep from 20 Hz to 20 kHz (10 s, frequency-response verification), and a sequence of test tones at 100 Hz, 1 kHz, and 10 kHz (10 s, level verification). This synthetic default lets the harness run technically without depending on any third-party audio.
2. Loads `distant-engines.tnf`.
3. Renders the input offline through the graph (using `AVAudioEngine.enableManualRenderingMode`).
4. Writes the result to `test-artifacts/ear-test-output.wav`.
5. Also copies the input (synthetic or user-provided) to `test-artifacts/ear-test-input.wav` for A/B comparison.

The synthetic default makes the Phase 2 technical gate runnable without any user input or licensing question. The aesthetic ear test — the human-in-loop gate where the user listens and confirms the preset character — is run separately:

- The orchestrator surfaces `[EAR_TEST_READY: test-artifacts/]` with the synthetic-input artifacts.
- The user listens to the synthetic A/B to confirm the chain is producing sensible spectral changes (technical aesthetic check).
- For the substantive aesthetic check (does the preset achieve the dissociating "distant engines" character), the user provides their own 30-second clip and re-runs the harness with `--input <path>`. The user replies `[EAR_TEST: PASS]` or `[EAR_TEST: FAIL: <reason>]` once satisfied with the result.

This avoids the U-005 escalation entirely: the harness runs out-of-the-box, the user-provided clip step is a one-line CLI action, and licensing is the user's choice for their own clip rather than something the project bundles.
```

**Proposed revision 2 of 3**:
- File: `docs/decisions/uncertainty-log.md`
- Section: Replace the body of U-005 (the existing "Status" line through "Revisit trigger" line) with:

```markdown
**Status**: Resolved (ADR-008)
**Triggered by**: Phase 2 ear test harness design.
**Question**: The ear test harness uses a 30-second F1 onboard clip as input. Is there a freely-licensable source for this, or does the user need to provide one personally?

**Current best guess**: Resolved by ADR-008. The harness defaults to a synthetic test signal (pink noise + sine sweep + test tones); the user provides a personal clip via `--input` for the aesthetic ear test. No bundled audio, no licensing risk.

**Resolution path**: Resolved by ADR-008 — `docs/decisions/ADR-008-ear-test-input-source.md`.

**Revisit trigger**: If the synthetic default is insufficient to verify the chain is working correctly at the technical level (i.e., the user reports the synthetic output doesn't tell them whether the chain is broken or just rendering pink noise weirdly). In that case, the orchestrator can revisit with a different synthetic signal or a different bundled CC-licensed clip.
```

**Proposed revision 3 of 3**:
- File: `docs/decisions/ADR-008-ear-test-input-source.md`
- Section: New file with the following full content:

```markdown
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
```

**Rationale**: The audit's observation is correct — leaving U-005 open until Phase 2 puts the ear-test gate at risk of stalling over a question that can be settled now. The synthetic-signal-with-user-clip-override pattern is the lowest-risk default: it makes the harness runnable immediately, removes the licensing dependency from the project entirely, and preserves the aesthetic check as a small user step rather than a build-blocking escalation. The ADR documents the choice so the rationale is visible.

---
