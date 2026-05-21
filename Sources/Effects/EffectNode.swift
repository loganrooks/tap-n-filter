import AVFoundation
import Foundation

/// The contract every audio effect implements.
///
/// `EffectNode` decouples the graph layer (`docs/specs/audio-graph.md`) from
/// concrete effects so the graph can wire arbitrary effect chains by name
/// without knowing the underlying `AVAudioUnit` types. See
/// `docs/specs/effect-node-protocol.md`.
///
/// Every node owns its own wet/dry mixing scaffolding (input fan-out mixer,
/// output summing mixer, unity dry-path mixer, and a wet-path processor).
/// The graph treats each node as a single in / single out box and never
/// looks inside.
public protocol EffectNode: AnyObject, Codable {

    /// Stable type identifier used in serialization and registry lookup.
    /// Convention: `"tnf.<short-name>"`, e.g. `"tnf.eq"`, `"tnf.reverb"`.
    static var typeIdentifier: String { get }

    /// Whether the EffectRow surfaces the wet/dry slider in its always-visible
    /// header. Time-domain effects (reverb, delay) override-or-default to
    /// `true`; spectral-shaping effects (EQ, filters) override to `false`
    /// because mixing dry back in defeats the filter. See ADR-007.
    static var showsWetDryByDefault: Bool { get }

    /// Per-instance identifier preserved across save/load.
    var id: UUID { get }

    /// User-visible name. Defaults to the type's default display name; the
    /// user may rename it.
    var displayName: String { get set }

    /// When true the wet path is muted and the dry path is at unity, so the
    /// node passes audio through unchanged.
    var bypass: Bool { get set }

    /// 0.0 → fully dry (input passes through), 1.0 → fully wet (effect-only).
    /// Implemented at the node level via the parallel-mixer pattern; see the
    /// "Wet/dry mixing convention" section in
    /// `docs/specs/effect-node-protocol.md`.
    var wetDryMix: Float { get set }

    /// Metadata for every tunable parameter the effect exposes.
    var parameters: [EffectParameter] { get }

    /// Update a parameter by identifier. Throws if the identifier is unknown
    /// or if the value falls outside the parameter's declared range.
    func setParameter(_ identifier: String, value: Float) throws

    /// Attach all underlying `AVAudioUnit`s and internal mixers to `engine`.
    /// After this call returns successfully, `inputBus` and `outputBus` are
    /// valid and connectable by the graph.
    ///
    /// The node is responsible for setting the volumes on `outputBus`'s wet
    /// and dry input buses according to the current `bypass` and `wetDryMix`
    /// values.
    func attach(to engine: AVAudioEngine) throws

    /// Detach from the engine. After this call, `inputBus` and `outputBus`
    /// must not be connected by the graph.
    func detach()

    /// The mixer node the graph connects audio INTO (bus 0). The node uses
    /// the mixer's higher output buses internally to fan out to the dry and
    /// wet paths.
    var inputBus: AVAudioMixerNode { get }

    /// The mixer node the graph connects audio OUT OF (bus 0). The node
    /// connects its dry and wet paths to higher input buses on this mixer
    /// and implements `wetDryMix` via per-input-bus volumes.
    var outputBus: AVAudioMixerNode { get }

    /// Capture the node's current state for serialization.
    func snapshot() -> EffectState

    /// Apply a previously-captured state. Out-of-range parameter values are
    /// clamped to range (forward-compat with later schema changes); unknown
    /// parameter identifiers are ignored.
    func restore(from state: EffectState) throws
}

extension EffectNode {

    /// Default value for `showsWetDryByDefault`. Time-domain effects accept
    /// the default; spectral-shaping effects override to `false`.
    public static var showsWetDryByDefault: Bool { true }

    /// Codable default for nodes that don't need a bespoke encoding path.
    /// Encoding goes through `snapshot()` so the on-disk shape exactly
    /// matches `EffectState`.
    public func encode(to encoder: Encoder) throws {
        try snapshot().encode(to: encoder)
    }

    /// Default `init(from:)` throws because protocols cannot construct
    /// conforming types. The primary deserialization path is
    /// `Graph.restore(from:using:)` (via `EffectNodeRegistry`), which never
    /// calls this initializer. Concrete types may override for the future
    /// "import single effect" feature; V1 does not exercise that path.
    ///
    /// Throwing here (rather than `fatalError`) keeps a misuse recoverable
    /// and avoids a hard crash in release builds if this path is accidentally
    /// exercised.
    public init(from decoder: Decoder) throws {
        throw DecodingError.dataCorrupted(
            .init(
                codingPath: decoder.codingPath,
                debugDescription:
                    "Concrete EffectNode types must implement init(from:) if direct "
                    + "decoding is required. The primary load path is "
                    + "Graph.restore(from:using:) — see docs/specs/preset-format.md."
            )
        )
    }
}
