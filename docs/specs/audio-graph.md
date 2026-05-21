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

`attach` performs all engine mutations inside an `engine.pause()` / `engine.prepare()` block. The sequence:

1. For each node in `nodes`, call `node.attach(to: engine)`. The node attaches its own underlying `AVAudioUnit` (or composite) to the engine.
2. Connect `source` to `nodes[0].inputBus`.
3. For each adjacent pair `(nodes[i], nodes[i+1])`, connect `nodes[i].outputBus` to `nodes[i+1].inputBus`.
4. Connect `nodes[last].outputBus` to a `AVAudioMixerNode` that applies `outputGain`.
5. Connect that mixer to `destination`.

Format negotiation: each `connect` uses the source node's `outputFormat(forBus: 0)`. The graph does not insert format converters; nodes are expected to produce a format compatible with the next node's input.

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

Adding, removing, or reordering nodes while audio is flowing requires care. The standard pattern:

1. Save the current graph snapshot (in case rollback is needed).
2. Pause the engine: `engine.pause()`.
3. Mutate the graph.
4. Detach and re-attach the graph (sequence preserved across the mutation).
5. Resume: `engine.prepare()` and `engine.start()`.

The UI layer (Phase 3) presents this as instant, but internally there's a brief pause (typically a few milliseconds). Users notice the silence; the orchestrator can mitigate by fading output gain to zero, mutating, then fading back, but V1 does not implement this — the brief click on mutations is acceptable.

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
