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
1. Loads a known input wav from `Resources/EarTestInput/onboard-30s.wav` (a 30-second F1 onboard clip licensed for testing — the orchestrator surfaces `[ESCALATION: ear-test-input-source]` if no licensed clip is identified; an alternative is for the user to provide one).
2. Loads `distant-engines.tnf`.
3. Renders the input offline through the graph (using `AVAudioEngine.enableManualRenderingMode`).
4. Writes the result to `test-artifacts/ear-test-output.wav`.
5. Also copies the input to `test-artifacts/ear-test-input.wav` for A/B comparison.

The orchestrator surfaces `[EAR_TEST_READY: test-artifacts/]` in transcript.

## Gate criteria

Phase 2 PASSES when ALL of the following are true:

1. The verification subagent confirms:
   a. EffectNode, Graph, EQNode, ReverbNode all exist with the specified surface.
   b. Unit tests pass in CI.
   c. The "distant-engines" preset loads correctly from disk and produces non-silent output through the offline render.
   d. CodeRabbit and Codex have reviewed the PR with High-severity findings addressed.
2. The ear test artifact pair exists at `test-artifacts/`.
3. The user has confirmed `[EAR_TEST: PASS]` in transcript.

If the user confirms `[EAR_TEST: FAIL: <reason>]`, the orchestrator analyzes the failure reason. If the failure is a parameter-tuning issue (e.g., "too wet", "lowpass not aggressive enough"), the orchestrator iterates on the preset and re-renders. If the failure is structural (e.g., "this doesn't sound right at any settings"), the orchestrator escalates: `[ESCALATION: ear-test-structural-fail]`. Three failed ear tests in a row triggers automatic escalation regardless of reason.

## Failure modes

- **AVAudioUnitReverb factory presets don't achieve the dissociating quality.** The fallback is to implement a custom convolution node loading IRs from `Resources/IR/`. This is moved out of V1 by default but the architecture supports adding it. If the ear test fails for this reason, the orchestrator writes ADR-007-custom-ir-implementation and treats it as an in-scope extension to Phase 2 (not a new phase).
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
