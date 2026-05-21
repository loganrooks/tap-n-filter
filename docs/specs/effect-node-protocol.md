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
    
    /// Mix between fully dry (0.0) and fully wet (1.0). 0.5 is equal.
    var wetDryMix: Float { get set }
    
    /// The parameters this effect exposes.
    var parameters: [EffectParameter] { get }
    
    /// Update a parameter by identifier. Throws if the identifier is unknown
    /// or the value is outside the parameter's range.
    func setParameter(_ identifier: String, value: Float) throws
    
    /// Attach the underlying AVAudioUnit(s) to the engine. Called by the graph
    /// during `Graph.attach`.
    func attach(to engine: AVAudioEngine) throws
    
    /// Detach from the engine. Called by the graph during `Graph.detach`.
    func detach()
    
    /// The node the graph connects audio INTO. This is typically a mixer
    /// that fans out to dry and wet paths.
    var inputBus: AVAudioNode { get }
    
    /// The node the graph connects audio OUT OF. Typically a mixer that
    /// combines dry and wet paths.
    var outputBus: AVAudioNode { get }
    
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
        inputBus (AVAudioMixerNode)
         /                \
        / dry path        \ wet path
       /                   \
   [dry gain]            [effect AVAudioUnit]
       \                   /
        \                 / 
         \               /
        outputBus (AVAudioMixerNode mixing dry + wet)
```

`inputBus` is an `AVAudioMixerNode` that fans out to both paths. `outputBus` is another `AVAudioMixerNode` summing them. The mix is set by adjusting the per-input gain of `outputBus`:

- Dry gain = `1.0 - wetDryMix`
- Wet gain = `wetDryMix`

This means `wetDryMix = 0.5` produces equal-power mixing only approximately. For V1 this is acceptable. For V2, a future revision can use sin/cos equal-power curves if needed; the protocol surface doesn't change.

## Bypass

When `bypass = true`, the effect's underlying `AVAudioUnit` is still attached to the engine, but the wet path's mixer gain is set to zero. This avoids the click that engine restructuring would cause. The dry path is set to 1.0.

When `bypass = false`, dry and wet gains follow `wetDryMix` as described above.

## Codable conformance

The `Codable` conformance on `EffectNode` is implemented by encoding/decoding the `EffectState`. The default implementation:

```swift
extension EffectNode {
    public func encode(to encoder: Encoder) throws {
        try snapshot().encode(to: encoder)
    }
    
    public init(from decoder: Decoder) throws {
        // Concrete types implement this — the protocol can't because it needs
        // type-specific construction. The init reads the EffectState and 
        // constructs the node, then calls restore(from:).
        fatalError("Concrete EffectNode must implement init(from:)")
    }
}
```

For a list of `any EffectNode` (the graph's `nodes` array), serialization uses a discriminated-union pattern keyed on `typeIdentifier`. The `GraphPreset` Codable implementation handles this — see `docs/specs/preset-format.md`.

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
