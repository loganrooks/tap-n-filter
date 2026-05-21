# Audio Graph

The `Graph` is the central data structure of the audio side of the app. It owns an ordered list of effect nodes, each conforming to the `EffectNode` protocol (`docs/specs/effect-node-protocol.md`). The graph manages connections between nodes and between the graph endpoints and the rest of the audio engine.

## Conceptual model

A graph is a linear chain:

```
   input → node[0] → node[1] → … → node[n] → outputGain → output
```

Nodes are ordered. Each node has one input bus and one output bus. The graph wires them sequentially. There is no branching or parallel routing at the graph level in V1. Wet/dry mixing happens **inside each node** so the graph itself stays linear.

A future version may support parallel routes, but the V1 protocol does not preclude this — the graph would simply gain a sibling type like `ParallelGraph` that conforms to the same external interface.

## The `Graph` type

```swift
public final class Graph {
    public private(set) var nodes: [any EffectNode]
    public var outputGain: Float  // 0.0 ... 2.0, default 1.0
    
    public init(nodes: [any EffectNode] = [], outputGain: Float = 1.0) {
        self.nodes = nodes
        self.outputGain = outputGain
    }
    
    /// Attach all nodes to the engine and wire them in sequence.
    /// `source` and `destination` are the engine nodes the graph connects between.
    public func attach(to engine: AVAudioEngine,
                       source: AVAudioNode,
                       destination: AVAudioNode) throws
    
    /// Detach all nodes from the engine.
    public func detach()
    
    public func add(_ node: any EffectNode, at index: Int? = nil) throws
    public func remove(at index: Int) throws
    public func move(from: Int, to: Int) throws
    
    public func snapshot() -> GraphPreset
    public static func restore(from preset: GraphPreset,
                               using registry: EffectNodeRegistry) throws -> Graph
}
```

### `attach`

`attach` is called only when the engine is in a state where reconfiguration is permitted: either before `engine.start()` has been called for this session, or after `engine.stop()` (a full stop, not `engine.pause()`). Calling `attach` against a running or paused engine is a programming error in V1; the graph asserts on this and the caller (`AppViewModel`) is responsible for stopping the engine before any graph attach or mutation.

The sequence:

1. For each node in `nodes`, call `node.attach(to: engine)`. The node creates its mixer scaffolding (per the wet/dry mixing convention in `effect-node-protocol.md`), attaches its underlying `AVAudioUnit`s plus mixers to the engine, and connects its internal dry and wet paths to the appropriate input buses on its `outputBus`.
2. Connect `source` to `nodes[0].inputBus` on bus 0 with the source's `outputFormat(forBus: 0)`.
3. For each adjacent pair `(nodes[i], nodes[i+1])`, connect `nodes[i].outputBus` bus 0 to `nodes[i+1].inputBus` bus 0 with the upstream output format.
4. Connect `nodes[last].outputBus` bus 0 to a graph-owned `AVAudioMixerNode` that applies `outputGain` (set via its single-input bus volume).
5. Connect that mixer to `destination` bus 0.

Format negotiation: each `connect` uses the source node's `outputFormat(forBus: 0)`. The graph does not insert format converters; nodes are expected to produce a format compatible with the next node's input. The aggregate device's native format is the format the chain runs at; sample rate and channel layout are determined by the device, not by the graph.

### `detach`

Disconnects all nodes from the engine, then calls `node.detach()` on each. After `detach`, the graph can be re-attached to a different engine (e.g., after engine restart).

### `add`, `remove`, `move`

Mutations require the graph to be either detached or for the engine to be paused. The orchestrator pauses the engine, mutates, re-attaches, then resumes.

The `EffectNodeRegistry` is a type that maps `typeIdentifier` strings to factory closures, used during preset restoration to instantiate the right concrete node type.

### `snapshot` and `restore`

`snapshot` returns a `GraphPreset` containing each node's `snapshot()` plus `outputGain`. Round-tripping (snapshot → JSON → restore) must preserve all parameter values exactly.

`restore` is a static factory that uses an `EffectNodeRegistry` to instantiate nodes of the correct type, then applies their saved state.

## `EffectNodeRegistry`

```swift
public final class EffectNodeRegistry {
    public static let shared: EffectNodeRegistry = {
        let r = EffectNodeRegistry()
        r.register(EQNode.self)
        r.register(ReverbNode.self)
        return r
    }()
    
    public func register<T: EffectNode>(_ type: T.Type)
    public func makeNode(typeIdentifier: String) throws -> any EffectNode
}
```

Adding a new effect type to the app means writing the `EffectNode` and registering it with the shared registry. The registry is the single place where effect types are enumerated, which matters for the preset menu, the "Add effect" UI, and serialization.

## Graph mutations during playback

Adding, removing, or reordering nodes while audio is flowing requires care. `AVAudioEngine.pause()` is not sufficient — `attach`, `connect`, and `detach` calls on an engine that has been started require the engine to be fully stopped (`engine.stop()`), or the engine reports the connection as a no-op and audio routing silently breaks. The standard pattern:

1. Save the current graph snapshot (in case rollback is needed).
2. Stop the engine: `engine.stop()`. This drains the render loop fully.
3. Detach all nodes from the engine via `graph.detach()`.
4. Mutate the graph (add/remove/move).
5. Re-attach via `graph.attach(to:source:destination:)` with the same source and destination as the prior attach.
6. Start the engine: `engine.start()`.

The UI layer (Phase 3) presents this as instant, but internally there's a brief silence (typically 50–150 ms). Users notice the silence; the orchestrator can mitigate by fading output gain to zero, mutating, then fading back, but V1 does not implement this — the brief silence on mutations is acceptable.

The lifecycle constraint here is documented in `ADR-006-graph-mutation-lifecycle.md`.

## Error handling

`attach` can fail if a node's `attach` throws or if engine connection fails. On failure, the graph attempts a clean rollback: any nodes that were partially attached are detached, and the error propagates. The view model is responsible for surfacing the error to the user.

`add`, `remove`, `move` are non-throwing for invalid indices in V1 — invalid index calls are no-ops with a logged warning. (The UI shouldn't generate invalid indices.)

## Testing

The graph is tested using a `MockEffectNode` that conforms to `EffectNode` without any real DSP. Tests cover:
- Empty graph: input passes through to output unchanged (with outputGain applied).
- Single-node graph: input → node → output.
- Multi-node graph: input → node[0] → node[1] → output, with each node's transformation reflected in the output.
- Mutations: add at start, add at end, add in middle, remove, move; verify output reflects the new chain.
- Round-trip serialization: snapshot → JSON → restore → snapshot equals original.

The `Graph` does not directly invoke real DSP in unit tests; that's tested at the effect level.
