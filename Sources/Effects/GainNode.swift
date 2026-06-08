import AVFoundation
import Foundation

/// A level-trim effect: one gain knob in decibels, applied by a single
/// `AVAudioMixerNode`'s output volume.
///
/// `GainNode` is the simplest concrete `EffectNode`. It holds no `AVAudioUnit`
/// — the gain is realised entirely by the mixer's `outputVolume`, so the node
/// is a single attachable object that doubles as both `inputBus` and
/// `outputBus`. The graph wires `source → mixer → next`; the mixer scales.
///
/// Unlike `EQNode` and `ReverbNode`, a gain trim has no wet/dry concept: a
/// partial blend of "the level-changed signal" with "the original" is just a
/// different effective level, never a useful effect. `supportsWetDry` is
/// therefore `false` and the UI suppresses the wet/dry control entirely.
/// `bypass` still works: it forces unity so the user can A/B their trim
/// without losing the dialled-in value.
///
/// See `docs/specs/effect-node-protocol.md` and ADR-021 (the always-on output
/// safety limiter that backstops the boost this node can apply).
public final class GainNode: EffectNode {

    // MARK: Type-level metadata

    public static let typeIdentifier: String = "tnf.gain"

    /// A gain trim has no wet/dry path at all; see the type doc. The UI hides
    /// the wet/dry control everywhere for this node.
    public static let supportsWetDry: Bool = false

    /// With no wet/dry concept there is nothing to show in the row header.
    public static let showsWetDryByDefault: Bool = false

    private static let defaultDisplayName: String = "Gain"

    /// Identifier of the single decibel parameter.
    public static let gainParameterIdentifier: String = "gain"

    // MARK: Instance state

    /// Per-instance identifier preserved across save/load cycles.
    public var id: UUID
    /// User-visible name for this node instance (may differ from the type default).
    public var displayName: String

    public var bypass: Bool {
        didSet { applyGain() }
    }

    /// Inert for `GainNode` (`supportsWetDry == false`). Stored only so the
    /// `EffectState` round-trip preserves whatever a preset carries; it never
    /// affects the rendered signal.
    public var wetDryMix: Float

    /// The trim, in decibels. Clamped to the parameter range on assignment
    /// via `setParameter`; direct assignment is clamped at apply time. 0 dB is
    /// unity.
    public private(set) var gainDecibels: Float {
        didSet { applyGain() }
    }

    /// The single mixer that both receives and emits audio. The gain is its
    /// `outputVolume`. Returned as both `inputBus` and `outputBus`.
    private let mixer: AVAudioMixerNode

    public var inputBus: AVAudioMixerNode { mixer }
    public var outputBus: AVAudioMixerNode { mixer }

    private weak var attachedEngine: AVAudioEngine?

    // MARK: Init

    /// Convenience initializer used by the registry — produces a node at unity.
    public convenience init() {
        self.init(id: UUID())
    }

    /// Full initializer. `displayName` defaults to `"Gain"` when nil.
    /// `gainDecibels` defaults to 0 dB (unity). Out-of-range values are clamped
    /// to the parameter range so a node can never be constructed in an invalid
    /// state.
    public init(
        id: UUID = UUID(),
        displayName: String? = nil,
        bypass: Bool = false,
        gainDecibels: Float = 0.0
    ) {
        self.id = id
        self.displayName = displayName ?? Self.defaultDisplayName
        self.bypass = bypass
        self.wetDryMix = 1.0
        self.gainDecibels = Self.clampToRange(gainDecibels)
        self.mixer = AVAudioMixerNode()
    }

    // MARK: Parameters

    /// All tunable parameters for this node type, in display order.
    ///
    /// The range tops out at +12 dB rather than the symmetric +24 dB a console
    /// trim might offer: the gain is applied through `AVAudioMixerNode`'s
    /// `outputVolume`, which the project already drives above unity for the
    /// graph's output trim (0–2×); +12 dB (≈3.98×) stays within that proven
    /// envelope. The always-on output limiter (ADR-021) backstops the boost.
    public static let parameterCatalog: [EffectParameter] = [
        EffectParameter(
            identifier: GainNode.gainParameterIdentifier,
            displayName: "Gain",
            range: -24.0 ... 12.0,
            defaultValue: 0.0,
            unit: .decibels
        )
    ]

    public var parameters: [EffectParameter] { Self.parameterCatalog }

    public func setParameter(_ identifier: String, value: Float) throws {
        guard let parameter = Self.parameterCatalog.first(where: { $0.identifier == identifier })
        else {
            throw EffectParameterError.unknownParameter(identifier: identifier)
        }
        guard parameter.range.contains(value) else {
            throw EffectParameterError.valueOutOfRange(
                identifier: identifier,
                value: value,
                range: parameter.range
            )
        }
        // Only `gain` is registered, so a passing range check implies this id.
        gainDecibels = value
    }

    public func parameterValue(_ identifier: String) -> Float? {
        identifier == Self.gainParameterIdentifier ? gainDecibels : nil
    }

    // MARK: Attach / detach

    public func attach(to engine: AVAudioEngine) throws {
        engine.attach(mixer)
        applyGain()
        attachedEngine = engine
    }

    public func detach() {
        guard let engine = attachedEngine else { return }
        engine.detach(mixer)
        attachedEngine = nil
    }

    /// Convert the decibel trim to a linear factor and write it to the mixer.
    ///
    /// `outputVolume` is a direct property of `AVAudioMixerNode` (not an
    /// `AVAudioMixingDestination`), so unlike the parallel-mixer nodes this
    /// value lands whether the engine is stopped or running; `refreshMixState`
    /// re-applies it only for symmetry with the rest of the chain.
    private func applyGain() {
        mixer.outputVolume = bypass ? 1.0 : Self.decibelsToLinear(gainDecibels)
    }

    public func refreshMixState() {
        applyGain()
    }

    // MARK: Diagnostics

    public func debugStateDescription() -> String {
        return "bypass=\(bypass) gainDecibels=\(gainDecibels) "
            + "linear=\(Self.decibelsToLinear(gainDecibels)) "
            + "outputVolume=\(mixer.outputVolume) "
            + "attached=\(attachedEngine != nil) "
            + "fmt=\(Self.fmt(mixer.outputFormat(forBus: 0)))"
    }

    private static func fmt(_ format: AVAudioFormat) -> String {
        return "\(format.sampleRate)Hz×\(format.channelCount)ch"
    }

    // MARK: Snapshot / restore

    public func snapshot() -> EffectState {
        EffectState(
            typeIdentifier: Self.typeIdentifier,
            id: id,
            displayName: displayName,
            bypass: bypass,
            wetDryMix: wetDryMix,
            parameters: [Self.gainParameterIdentifier: gainDecibels],
            extras: [:]
        )
    }

    public func restore(from state: EffectState) throws {
        guard state.typeIdentifier == Self.typeIdentifier else {
            throw EffectRestoreError.typeIdentifierMismatch(
                expected: Self.typeIdentifier,
                actual: state.typeIdentifier
            )
        }
        // Preserve identity across save/load, matching EQNode/ReverbNode.
        id = state.id
        displayName = state.displayName
        bypass = state.bypass
        wetDryMix = min(max(state.wetDryMix, 0.0), 1.0)
        if let raw = state.parameters[Self.gainParameterIdentifier] {
            gainDecibels = Self.clampToRange(raw)
        }
        applyGain()
    }

    // MARK: dB / linear conversion

    /// 10^(dB/20). 0 dB → 1.0, −6 dB → ≈0.5, +6 dB → ≈2.0.
    public static func decibelsToLinear(_ decibels: Float) -> Float {
        powf(10.0, decibels / 20.0)
    }

    /// Clamp a decibel value to the catalog's declared range.
    private static func clampToRange(_ decibels: Float) -> Float {
        let range = parameterCatalog[0].range
        return min(max(decibels, range.lowerBound), range.upperBound)
    }
}
