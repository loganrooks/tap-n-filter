import AVFoundation
import Foundation

/// A level-trim effect: one gain knob in decibels.
///
/// The gain is realised by `AVAudioUnitEQ.globalGain`, a documented master
/// gain (in dB) that supports both attenuation and boost. An earlier draft
/// scaled an `AVAudioMixerNode.outputVolume`, but that property's documented
/// range is 0.0–1.0, so relying on it for boost above unity is outside the API
/// contract (Codex review, PR #13). A zero-band EQ is a clean, documented gain
/// stage: no bands means a flat response, and `globalGain` does the work.
///
/// The graph sees the node as the usual single-in / single-out box via the
/// `inputBus` and `outputBus` mixers, with the EQ wired between them.
///
/// Unlike `EQNode` and `ReverbNode`, a gain trim has no wet/dry concept: a
/// partial blend of "the level-changed signal" with "the original" is just a
/// different effective level, never a useful effect. `supportsWetDry` is
/// therefore `false` and the UI suppresses the wet/dry control entirely.
/// `bypass` still works: it forces unity (0 dB) so the user can A/B their trim
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

    /// The graph connects audio into this node on bus 0.
    public let inputBus: AVAudioMixerNode
    /// The graph reads audio from this node on bus 0.
    public let outputBus: AVAudioMixerNode
    /// Zero-band EQ used purely as a documented dB gain stage via `globalGain`.
    private let gainUnit: AVAudioUnitEQ

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
        self.inputBus = AVAudioMixerNode()
        self.outputBus = AVAudioMixerNode()
        self.gainUnit = AVAudioUnitEQ(numberOfBands: 0)
    }

    // MARK: Parameters

    /// All tunable parameters for this node type, in display order.
    ///
    /// `AVAudioUnitEQ.globalGain` accepts roughly −96…+24 dB; the −24…+12 dB
    /// surface range is the useful trim envelope, with the boost backstopped by
    /// the always-on output limiter (ADR-021).
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
        engine.attach(inputBus)
        engine.attach(gainUnit)
        engine.attach(outputBus)

        // Linear pass-through: inputBus → gainUnit → outputBus. Internal links
        // use format nil so they inherit the format the graph pins on the
        // external source → inputBus connection (the same convention EQNode
        // uses); this keeps the H17 capture-rate pin intact.
        engine.connect(inputBus, to: gainUnit, format: nil)
        engine.connect(gainUnit, to: outputBus, format: nil)

        applyGain()
        attachedEngine = engine
    }

    public func detach() {
        guard let engine = attachedEngine else { return }
        engine.detach(gainUnit)
        engine.detach(outputBus)
        engine.detach(inputBus)
        attachedEngine = nil
    }

    /// Write the decibel trim to the EQ's global gain. `globalGain` is in dB
    /// and is settable whether the engine is stopped or running; bypass forces
    /// 0 dB (unity).
    private func applyGain() {
        gainUnit.globalGain = bypass ? 0.0 : gainDecibels
    }

    public func refreshMixState() {
        applyGain()
    }

    // MARK: Diagnostics

    public func debugStateDescription() -> String {
        return "bypass=\(bypass) gainDecibels=\(gainDecibels) "
            + "globalGain=\(gainUnit.globalGain) "
            + "attached=\(attachedEngine != nil) "
            + "inFmt=\(Self.fmt(inputBus.outputFormat(forBus: 0))) "
            + "outFmt=\(Self.fmt(outputBus.outputFormat(forBus: 0)))"
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

    // MARK: Range clamping

    /// Clamp a decibel value to the catalog's declared range.
    private static func clampToRange(_ decibels: Float) -> Float {
        let range = parameterCatalog[0].range
        return min(max(decibels, range.lowerBound), range.upperBound)
    }
}
