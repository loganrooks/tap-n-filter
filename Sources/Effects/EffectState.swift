import Foundation

/// Serialization-shaped snapshot of an `EffectNode`'s state.
///
/// `EffectState` is the on-disk and over-the-wire representation of a single
/// effect. It is intentionally a value type with only `Codable` primitive
/// fields, so it round-trips cleanly through JSON without protocol-witness
/// machinery. See `docs/specs/preset-format.md` for the full format.
public struct EffectState: Codable, Equatable {

    /// Stable identifier of the concrete `EffectNode` type. Used at load time
    /// by `EffectNodeRegistry` to instantiate the right class.
    public let typeIdentifier: String

    /// Instance identifier preserved across save/load.
    public let id: UUID

    /// User-facing name (may equal the type's default).
    public let displayName: String

    /// Whether the effect was bypassed at snapshot time.
    public let bypass: Bool

    /// Wet/dry mix at snapshot time. Range 0.0–1.0.
    public let wetDryMix: Float

    /// Parameter values keyed by parameter identifier.
    public let parameters: [String: Float]

    /// Type-specific state that doesn't fit `parameters` (e.g. reverb preset).
    public let extras: [String: AnyCodableValue]

    public init(
        typeIdentifier: String,
        id: UUID,
        displayName: String,
        bypass: Bool,
        wetDryMix: Float,
        parameters: [String: Float],
        extras: [String: AnyCodableValue]
    ) {
        self.typeIdentifier = typeIdentifier
        self.id = id
        self.displayName = displayName
        self.bypass = bypass
        self.wetDryMix = wetDryMix
        self.parameters = parameters
        self.extras = extras
    }
}
