# EffectNode Protocol

The `EffectNode` protocol defines what an audio effect is in tap-n-filter. Every effect — built-in or future — conforms to this protocol. The protocol is the contract between the graph layer (`docs/specs/audio-graph.md`) and the concrete effects.

## Definition

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

## Supporting types

```swift
public struct EffectParameter {
    public let identifier: String   // stable, e.g. "lp.frequency"
    public let displayName: String  // user-visible
    public let range: ClosedRange<Float>
    public let defaultValue: Float
    public let unit: ParameterUnit
}

public enum ParameterUnit {
    case hertz
    case decibels
    case ratio          // unitless ratio, e.g. Q
    case seconds
    case milliseconds
    case normalized     // 0–1
    case percent        // 0–100
    case integer        // discrete int values within the range
    case enumValue(cases: [String])  // for enum-valued parameters
}

public struct EffectState: Codable {
    public let typeIdentifier: String
    public let id: UUID
    public let displayName: String
    public let bypass: Bool
    public let wetDryMix: Float
    public let parameters: [String: Float]
    public let extras: [String: AnyCodableValue]
}
```

`AnyCodableValue` is a small wrapper enabling `Codable` storage of heterogeneous primitive types (string, int, double, bool, array, dictionary). Used for type-specific state that doesn't fit the simple `parameters` dictionary (e.g., enum-valued reverb preset stored as an int but logically a categorical choice).

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

### When wet/dry is meaningful

Wet/dry mixing is meaningful for time-domain effects where the wet path produces a signal distinct from the input (reverb tails, delay echoes, distortion harmonics). For these effects, mixing dry input back in at `wetDryMix < 1.0` reduces the effect's prominence without changing its character.

Wet/dry mixing is **less meaningful** for spectral-shaping effects (EQ, filters) where the wet path is the input with selected frequency content removed. At `wetDryMix = 0.5` for an EQ that filters frequency F, half of frequency F is summed back from the dry path, defeating the filter. For such effects, the meaningful operating value is `wetDryMix = 1.0` (fully wet, full filtering) and the bypass toggle handles the "no effect" case.

The protocol still requires `wetDryMix` on every node — the uniformity of the protocol surface is load-bearing for the graph layer, the UI's per-row controls, and serialization. Concrete nodes that don't meaningfully benefit from wet/dry mixing implement the protocol normally and document the limitation in their doc comments. The UI (`docs/specs/ui.md`) governs which nodes expose the wet/dry slider visibly. See `docs/decisions/ADR-007-wet-dry-on-eq.md`.

## Bypass

When `bypass = true`, the effect's underlying `AVAudioUnit` is still attached to the engine, but the wet path's mixer gain is set to zero. This avoids the click that engine restructuring would cause. The dry path is set to 1.0.

When `bypass = false`, dry and wet gains follow `wetDryMix` as described above.

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

## Implementing a new effect

A new effect type implements:

1. Declare a class conforming to `EffectNode`.
2. Set `static let typeIdentifier = "tnf.<name>"`.
3. Declare an `AVAudioUnit` (or composite) as the wet-path processor.
4. Construct the dry/wet mixer scaffolding in `init`.
5. Declare `parameters: [EffectParameter]`.
6. Implement `setParameter` to dispatch on identifier and update the underlying `AVAudioUnit`.
7. Implement `snapshot` and `restore` for serialization.
8. Implement `init(from decoder: Decoder)` to deserialize.
9. Register with `EffectNodeRegistry.shared` (typically at app launch in `AppDelegate` or `App.init`).

For built-in effects, registration happens in `EffectNodeRegistry`'s initializer.

## Concrete effect references

V1 ships two effects:

- `EQNode` — see `docs/specs/effects/eq.md` (TODO: extract into separate file if it grows; for now, content is inlined in `02-dsp-chain.md`).
- `ReverbNode` — same.

Future:

- `ConvolutionNode` for custom IR reverb.
- `DistortionNode` wrapping `AVAudioUnitDistortion`.
- `DelayNode` wrapping `AVAudioUnitDelay`.
- `AUv3Node` hosting third-party AUv3 plugins (V2).

## Testing

Each concrete effect has:

- Unit tests for parameter range enforcement.
- Unit tests for bypass behavior (offline render, verify dry = input).
- Unit tests for wet/dry endpoints (wetDryMix=0 → dry; wetDryMix=1 → fully wet).
- Round-trip Codable tests: encode → JSON → decode → equal state.

The `EffectNode` protocol itself is tested via the graph tests (`audio-graph.md`) using `MockEffectNode`.
