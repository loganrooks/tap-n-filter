import Foundation

/// Describes a single user-tunable parameter exposed by an `EffectNode`.
///
/// `EffectParameter` is purely descriptive metadata: the value itself lives on
/// the underlying `AVAudioUnit`. The UI uses this metadata to render labelled
/// sliders, and `setParameter(_:value:)` enforces the declared range.
///
/// See `docs/specs/effect-node-protocol.md`.
public struct EffectParameter: Equatable {

    /// Stable identifier used for dispatch and serialization.
    ///
    /// Convention: `"<band>.<name>"` for multi-band effects (e.g.
    /// `"hp.frequency"`), or a single word for everything else.
    public let identifier: String

    /// User-visible label. Localized at display time by the UI layer.
    public let displayName: String

    /// Inclusive range of legal values. `setParameter` throws when the value
    /// falls outside this range.
    public let range: ClosedRange<Float>

    /// Default value the parameter takes when a node is freshly constructed.
    public let defaultValue: Float

    /// The unit the value is expressed in. Used by the UI for formatting and
    /// by docs for description.
    public let unit: ParameterUnit

    public init(
        identifier: String,
        displayName: String,
        range: ClosedRange<Float>,
        defaultValue: Float,
        unit: ParameterUnit
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.range = range
        self.defaultValue = defaultValue
        self.unit = unit
    }
}
