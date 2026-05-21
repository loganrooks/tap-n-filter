# Phase 2: DSP Chain

Build the effect graph: the `EffectNode` protocol, the `Graph` type, the two concrete effect nodes (parametric EQ with HP+LP bands, and reverb), and the wet/dry mixing infrastructure. Wire this into the capture chain from Phase 1 so the source app's audio is filtered before output. End of phase has the first human-in-loop gate: the ear test.

## Scope

In:
- `EffectNode` protocol per `docs/specs/effect-node-protocol.md`.
- `Graph` type per `docs/specs/audio-graph.md`.
- `EQNode` — wraps `AVAudioUnitEQ` with HP and LP bands plus per-band frequency/Q/gain parameters.
- `ReverbNode` — wraps `AVAudioUnitReverb` with factory preset selection and wet/dry mix.
- Per-effect wet/dry mixing using parallel gain nodes.
- A `GraphPreset` Codable type for serialization.
- `.tnf` file load/save (basic — file dialog UI deferred to Phase 3, but the load/save logic exists).
- A bundled "distant-engines" preset for the ear test.
- Unit tests on each effect's parameter ranges and on graph serialization round-tripping.

Out:
- The full UI for editing the graph (Phase 3).
- Custom IR loading for the reverb (deferred; see uncertainty log).
- Additional effect types beyond EQ and Reverb (deferred).
- The source picker UI improvements (Phase 3).

## Reference

`docs/specs/audio-graph.md` documents the graph model.
`docs/specs/effect-node-protocol.md` documents the protocol every node conforms to.
`docs/specs/preset-format.md` documents the `.tnf` file format.

The orchestrator reads all three before writing any code in this phase.

## Architecture

```
   CaptureController (Phase 1)
            │
            ▼
   engine.inputNode
            │
            ▼
   ┌────────────────────────────┐
   │  Graph                     │
   │                            │
   │   EQNode (HP + LP)         │
   │      ↓                     │
   │   ReverbNode               │
   │      ↓                     │
   │   (output bus)             │
   └─────────────┬──────────────┘
                 │
                 ▼
         engine.mainMixerNode
                 │
                 ▼
         engine.outputNode
```

The `Graph` owns an ordered list of `EffectNode`s. Each node owns an `AVAudioUnit` (or composite of units) attached to the engine and connected in sequence. The graph's first node's input is connected to `engine.inputNode`; the last node's output is connected to `engine.mainMixerNode`.

Wet/dry per node is implemented inside each node: the node creates a parallel dry-path gain node and a wet-path through the effect, mixed by an internal mixer node, then exposes one input and one output to the graph. This keeps the graph-level wiring simple.

## Tasks

### 2.1 EffectNode protocol

Per `docs/specs/effect-node-protocol.md`, the protocol requires:

```swift
public protocol EffectNode: AnyObject, Codable {
    static var typeIdentifier: String { get }
    var id: UUID { get }
    var displayName: String { get set }
    var bypass: Bool { get set }
    var wetDryMix: Float { get set }  // 0.0 = fully dry, 1.0 = fully wet
    
    var parameters: [EffectParameter] { get }
    func setParameter(_ identifier: String, value: Float) throws
    
    func attach(to engine: AVAudioEngine) throws
    func detach()
    var inputBus: AVAudioNode { get }
    var outputBus: AVAudioNode { get }
    
    func snapshot() -> EffectState
    func restore(from state: EffectState) throws
}

public struct EffectParameter {
    public let identifier: String
    public let displayName: String
    public let range: ClosedRange<Float>
    public let defaultValue: Float
    public let unit: ParameterUnit  // .hertz, .decibels, .ratio, .seconds, .normalized
}

public struct EffectState: Codable {
    public let typeIdentifier: String
    public let id: UUID
    public let bypass: Bool
    public let wetDryMix: Float
    public let parameters: [String: Float]
    public let extras: [String: AnyCodableValue]  // for type-specific state
}
```

### 2.2 Graph type

Per `docs/specs/audio-graph.md`:

```swift
public final class Graph {
    public private(set) var nodes: [any EffectNode]
    public let outputGain: Float  // post-graph trim
    
    public func attach(to engine: AVAudioEngine,
                       source: AVAudioNode,
                       destination: AVAudioNode) throws
    public func detach()
    
    public func add(_ node: any EffectNode, at index: Int? = nil) throws
    public func remove(at index: Int) throws
    public func move(from: Int, to: Int) throws
    
    public func snapshot() -> GraphPreset
    public func restore(from preset: GraphPreset) throws
}

public struct GraphPreset: Codable {
    public let formatVersion: Int  // 1
    public let name: String
    public let nodes: [EffectState]
    public let outputGain: Float
}
```

### 2.3 EQNode

Wraps `AVAudioUnitEQ` configured with two bands:
- Band 0: high-pass, parameters `frequency` (20–500 Hz, default 80), `Q` (0.5–4, default 0.707).
- Band 1: low-pass, parameters `frequency` (200–18000 Hz, default 800), `Q` (0.5–4, default 0.707).

`wetDryMix` is implemented at the node level via the parallel-mixer pattern described in the spec.

### 2.4 ReverbNode

Wraps `AVAudioUnitReverb`. Parameters:
- `preset`: enum mapping to `AVAudioUnitReverbPreset` (smallRoom, mediumRoom, largeRoom, mediumHall, largeHall, plate, mediumChamber, largeChamber, cathedral, largeRoom2, mediumHall2, mediumHall3, largeHall2). Default `largeHall`.
- `wetDryMix` is the node's own parameter, mapped from 0–1 to the underlying `AVAudioUnitReverb.wetDryMix` (0–100).

### 2.5 Preset I/O

`GraphPreset` is JSON-serializable via `Codable`. File I/O lives in `PresetStore`:

```swift
public enum PresetStore {
    public static func load(from url: URL) throws -> GraphPreset
    public static func save(_ preset: GraphPreset, to url: URL) throws
}
```

The bundled "distant-engines" preset lives at `Resources/Presets/distant-engines.tnf` and is loaded by the app on first launch if no user presets exist.

### 2.6 Bundle the ear-test preset

`distant-engines.tnf`:
```json
{
  "formatVersion": 1,
  "name": "distant-engines",
  "outputGain": 0.0,
  "nodes": [
    {
      "typeIdentifier": "tnf.eq",
      "id": "...",
      "bypass": false,
      "wetDryMix": 1.0,
      "parameters": {
        "hp.frequency": 80.0,
        "hp.Q": 0.707,
        "lp.frequency": 800.0,
        "lp.Q": 1.2
      },
      "extras": {}
    },
    {
      "typeIdentifier": "tnf.reverb",
      "id": "...",
      "bypass": false,
      "wetDryMix": 0.7,
      "parameters": {
        "preset": 8
      },
      "extras": {}
    }
  ]
}
```
(`preset: 8` corresponds to `largeHall` in `AVAudioUnitReverbPreset` at time of writing — the orchestrator verifies the actual enum mapping during implementation.)

### 2.7 Tests

- Round-trip serialization: graph → JSON → graph, verify all parameters preserved.
- Each effect's parameter ranges: setting out-of-range throws.
- Bypass toggle: bypassed node passes input unchanged (testable with offline render).
- Wet/dry at 0.0: output equals input. At 1.0: output equals effect-only.
- Graph reordering: nodes can be reordered without crashes; output reflects the new order.

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

This resolves U-005: the harness runs out-of-the-box, the user-provided clip step is a one-line CLI action, and licensing is the user's choice for their own clip rather than something the project bundles. See `docs/decisions/ADR-008-ear-test-input-source.md`.

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

## Gate criteria

Phase 2 PASSES when ALL of the following are true:

1. The verification subagent confirms:
   a. EffectNode, Graph, EQNode, ReverbNode all exist with the specified surface.
   b. Unit tests pass in CI.
   c. The "distant-engines" preset loads correctly from disk and produces non-silent output through the offline render.
   d. CodeRabbit and Codex have reviewed the PR with High-severity findings addressed.
2. The ear test artifact pair exists at `test-artifacts/`.
3. The end-to-end live render check (section 2.9) has been run and either (a) the live render matches the offline render within the spectral tolerance documented in the verification report, or (b) any divergence has been resolved with documented changes (typically an ADR).
4. The user has confirmed `[EAR_TEST: PASS]` in transcript.

If the user confirms `[EAR_TEST: FAIL: <reason>]`, the orchestrator analyzes the failure reason. If the failure is a parameter-tuning issue (e.g., "too wet", "lowpass not aggressive enough"), the orchestrator iterates on the preset and re-renders. If the failure is structural (e.g., "this doesn't sound right at any settings"), the orchestrator escalates: `[ESCALATION: ear-test-structural-fail]`. Three failed ear tests in a row triggers automatic escalation regardless of reason.

## Failure modes

- **AVAudioUnitReverb factory presets don't achieve the dissociating quality.** The fallback is to implement a custom convolution node loading IRs from `Resources/IR/`. This is moved out of V1 by default but the architecture supports adding it. If the ear test fails for this reason, the orchestrator writes a new ADR (next free number — likely ADR-009 or later, depending on what the build has produced by then) for custom-ir-implementation and treats it as an in-scope extension to Phase 2 (not a new phase).
- **EffectNode protocol's Codable conformance is awkward for type-erased lists.** A type-safe Codable for `[any EffectNode]` requires an enum-based serialization wrapper. The spec at `docs/specs/effect-node-protocol.md` documents this pattern.
- **The offline render mode produces different output than real-time.** AVAudioEngine's manual rendering mode is well-supported, but the orchestrator should sanity-check by also confirming the same audible result in real-time playback (route a tab's audio through the chain live, listen briefly). This is for the orchestrator's confidence; the user's ear test is on the offline-rendered file.

## Outputs

- Effect graph implementation in `Sources/Graph/`.
- Concrete effects in `Sources/Effects/`.
- Preset I/O in `Sources/Presets/`.
- Tests in `Tests/GraphTests/`, `Tests/EffectsTests/`.
- Ear test harness in `Sources/EarTestHarness/`.
- The bundled preset in `Resources/Presets/`.
- A passing PR titled `phase-2: dsp chain`.
- Updated `state.json`: phase `2` → `passed`, `ear_test_result` recorded.
