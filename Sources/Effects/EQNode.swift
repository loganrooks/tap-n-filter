import AVFoundation
import Foundation

/// A two-band parametric EQ exposing a high-pass and a low-pass band.
///
/// Wraps `AVAudioUnitEQ` with two bands configured as resonant filters:
///
/// - Band 0 (`hp.*`): high-pass, default 80 Hz with Q 0.707.
/// - Band 1 (`lp.*`): low-pass, default 800 Hz with Q 0.707.
///
/// `wetDryMix` exists on the protocol but is unhelpful for spectral-shaping
/// effects (see ADR-007 and the protocol's "When wet/dry is meaningful"
/// section). The UI hides the slider by default via
/// `showsWetDryByDefault = false`; this class still implements the parallel-
/// mixer pattern correctly so the protocol surface stays uniform.
public final class EQNode: EffectNode {

    // MARK: Type-level metadata

    public static let typeIdentifier: String = "tnf.eq"

    /// Override the protocol default: dragging wet/dry on a filter reintroduces
    /// the very frequencies being removed. The slider is still reachable in
    /// the expanded controls panel; this only hides it from the default row.
    public static let showsWetDryByDefault: Bool = false

    private static let defaultDisplayName: String = "EQ"

    /// Bus index where the dry path connects on `outputBus`. Conventionally 0.
    private static let dryInputBusIndex: AVAudioNodeBus = 0

    /// Bus index where the wet path connects on `outputBus`. Conventionally 1.
    private static let wetInputBusIndex: AVAudioNodeBus = 1

    /// The mixer's only output bus. Fan-out is implemented via
    /// `connect(_:toConnectionPoints:fromBus:format:)`, not by using multiple
    /// output buses (a mixer has exactly one output bus).
    private static let sourceFanOutBus: AVAudioNodeBus = 0

    // MARK: Instance state

    /// Per-instance identifier preserved across save/load cycles.
    public var id: UUID
    /// User-visible name for this node instance (may differ from the type default).
    public var displayName: String

    public var bypass: Bool {
        didSet { applyMixGains() }
    }

    public var wetDryMix: Float {
        didSet { applyMixGains() }
    }

    /// The graph connects audio into this node on bus 0.
    public let inputBus: AVAudioMixerNode
    /// The graph reads audio from this node on bus 0.
    public let outputBus: AVAudioMixerNode
    private let dryMixer: AVAudioMixerNode
    /// A small mixer placed between the wet processor and `outputBus`. The
    /// processor (`AVAudioUnitEQ`) does not conform to `AVAudioMixing`, so
    /// we cannot set its volume on the downstream mixer directly. This
    /// trampoline mixer does conform and lets us route per-input-bus volume
    /// changes through the standard API.
    private let wetMixer: AVAudioMixerNode
    private let eq: AVAudioUnitEQ

    private weak var attachedEngine: AVAudioEngine?

    // MARK: Init

    /// Convenience initializer matching `DefaultConstructibleEffectNode`'s
    /// requirement. Equivalent to `init(id: UUID(), displayName: nil, ...)`.
    public convenience init() {
        self.init(id: UUID())
    }

    /// Full initializer. `displayName` defaults to `"EQ"` when nil.
    /// `wetDryMix` defaults to 1.0 (fully wet) because the EQ's filter is
    /// only meaningful at 100% wet; see ADR-007 and `showsWetDryByDefault`.
    public init(
        id: UUID = UUID(),
        displayName: String? = nil,
        bypass: Bool = false,
        wetDryMix: Float = 1.0
    ) {
        self.id = id
        self.displayName = displayName ?? Self.defaultDisplayName
        self.bypass = bypass
        self.wetDryMix = wetDryMix
        self.inputBus = AVAudioMixerNode()
        self.outputBus = AVAudioMixerNode()
        self.dryMixer = AVAudioMixerNode()
        self.wetMixer = AVAudioMixerNode()
        self.eq = AVAudioUnitEQ(numberOfBands: 2)
        configureEQBands()
    }

    private func configureEQBands() {
        // AVAudioUnitEQ's `globalGain` is in dB; the unit's overall gain is
        // unity at globalGain = 0.
        eq.globalGain = 0.0

        let hpBand = eq.bands[0]
        hpBand.filterType = .highPass
        hpBand.frequency = 80.0
        hpBand.bandwidth = qToBandwidth(0.707)
        hpBand.bypass = false

        let lpBand = eq.bands[1]
        lpBand.filterType = .lowPass
        lpBand.frequency = 800.0
        lpBand.bandwidth = qToBandwidth(0.707)
        lpBand.bypass = false
    }

    // MARK: Parameters

    /// All tunable parameters for this node type, in display order.
    public static let parameterCatalog: [EffectParameter] = [
        EffectParameter(
            identifier: "hp.frequency",
            displayName: "HP Frequency",
            range: 20.0 ... 500.0,
            defaultValue: 80.0,
            unit: .hertz
        ),
        EffectParameter(
            identifier: "hp.Q",
            displayName: "HP Q",
            range: 0.5 ... 4.0,
            defaultValue: 0.707,
            unit: .ratio
        ),
        EffectParameter(
            identifier: "lp.frequency",
            displayName: "LP Frequency",
            range: 200.0 ... 18_000.0,
            defaultValue: 800.0,
            unit: .hertz
        ),
        EffectParameter(
            identifier: "lp.Q",
            displayName: "LP Q",
            range: 0.5 ... 4.0,
            defaultValue: 0.707,
            unit: .ratio
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
        switch identifier {
        case "hp.frequency":
            eq.bands[0].frequency = value
        case "hp.Q":
            eq.bands[0].bandwidth = qToBandwidth(value)
        case "lp.frequency":
            eq.bands[1].frequency = value
        case "lp.Q":
            eq.bands[1].bandwidth = qToBandwidth(value)
        default:
            throw EffectParameterError.unknownParameter(identifier: identifier)
        }
    }

    /// Read the current value for a parameter by identifier.
    ///
    /// Returns `nil` for unknown identifiers. The Q parameters are converted
    /// back from the underlying bandwidth-in-octaves representation before
    /// being returned; the returned value matches the surface-facing Q scale.
    public func parameterValue(_ identifier: String) -> Float? {
        switch identifier {
        case "hp.frequency":
            return eq.bands[0].frequency
        case "hp.Q":
            return bandwidthToQ(eq.bands[0].bandwidth)
        case "lp.frequency":
            return eq.bands[1].frequency
        case "lp.Q":
            return bandwidthToQ(eq.bands[1].bandwidth)
        default:
            return nil
        }
    }

    // MARK: Attach / detach

    public func attach(to engine: AVAudioEngine) throws {
        // Attach all five nodes; AVAudioEngine.attach is idempotent.
        engine.attach(inputBus)
        engine.attach(outputBus)
        engine.attach(dryMixer)
        engine.attach(wetMixer)
        engine.attach(eq)

        // Fan out the input mixer's single output bus to both the dry path
        // and the wet path. AVAudioMixerNode has exactly one output bus;
        // fan-out is expressed through AVAudioConnectionPoint, not via
        // multiple `fromBus` values.
        let fanOut: [AVAudioConnectionPoint] = [
            AVAudioConnectionPoint(node: dryMixer, bus: 0),
            AVAudioConnectionPoint(node: eq, bus: 0)
        ]
        engine.connect(
            inputBus,
            to: fanOut,
            fromBus: Self.sourceFanOutBus,
            format: nil
        )

        // Bring the wet path through its trampoline mixer and merge into
        // the output summing mixer.
        engine.connect(eq, to: wetMixer, format: nil)
        engine.connect(
            dryMixer,
            to: outputBus,
            fromBus: 0,
            toBus: Self.dryInputBusIndex,
            format: nil
        )
        engine.connect(
            wetMixer,
            to: outputBus,
            fromBus: 0,
            toBus: Self.wetInputBusIndex,
            format: nil
        )

        applyMixGains()
        attachedEngine = engine
    }

    public func detach() {
        guard let engine = attachedEngine else { return }
        engine.detach(eq)
        engine.detach(wetMixer)
        engine.detach(dryMixer)
        engine.detach(outputBus)
        engine.detach(inputBus)
        attachedEngine = nil
    }

    private func applyMixGains() {
        let clampedMix = min(max(wetDryMix, 0.0), 1.0)
        let wetGain: Float = bypass ? 0.0 : clampedMix
        let dryGain: Float = bypass ? 1.0 : (1.0 - clampedMix)

        // EXP-031 fix: always keep the internal mixers' master `.volume`
        // at unity. See `ReverbNode.applyMixGains` for the rationale —
        // the documented way to mix is via `AVAudioMixingDestination.volume`
        // on the downstream mixer's per-input-bus destination, not via
        // the upstream mixer's `.volume`. The prior fallback path could
        // silently set `mixer.volume = 0` at attach time when the
        // destination was transiently unavailable, and that mute then
        // persisted across every subsequent call.
        dryMixer.volume = 1.0
        wetMixer.volume = 1.0

        if let dryDestination = dryMixer.destination(
            forMixer: outputBus,
            bus: Self.dryInputBusIndex
        ) {
            dryDestination.volume = dryGain
        }
        if let wetDestination = wetMixer.destination(
            forMixer: outputBus,
            bus: Self.wetInputBusIndex
        ) {
            wetDestination.volume = wetGain
        }
    }

    // MARK: - EXP-031 diagnostic

    /// `[EXP-031.*]` instrumentation. See `ReverbNode.debugStateDescription`
    /// for the rationale; identical shape so we can side-by-side compare
    /// Reverb (cuts audio on bypass) vs EQ (doesn't).
    public func debugStateDescription() -> String {
        let dryDest = dryMixer.destination(
            forMixer: outputBus,
            bus: Self.dryInputBusIndex
        )
        let wetDest = wetMixer.destination(
            forMixer: outputBus,
            bus: Self.wetInputBusIndex
        )
        return "bypass=\(bypass) wetDryMix=\(wetDryMix) "
            + "dryDestExists=\(dryDest != nil) "
            + "dryDestVol=\(dryDest?.volume.description ?? "nil") "
            + "dryMixerVol=\(dryMixer.volume) "
            + "wetDestExists=\(wetDest != nil) "
            + "wetDestVol=\(wetDest?.volume.description ?? "nil") "
            + "wetMixerVol=\(wetMixer.volume) "
            + "attached=\(attachedEngine != nil) "
            + "inFmt=\(Self.fmt(inputBus.outputFormat(forBus: 0))) "
            + "dryFmt=\(Self.fmt(dryMixer.outputFormat(forBus: 0))) "
            + "eqInFmt=\(Self.fmt(eq.inputFormat(forBus: 0))) "
            + "eqOutFmt=\(Self.fmt(eq.outputFormat(forBus: 0))) "
            + "wetFmt=\(Self.fmt(wetMixer.outputFormat(forBus: 0))) "
            + "outFmt=\(Self.fmt(outputBus.outputFormat(forBus: 0))) "
            + "eqAUBypass=\(eq.bypass)"
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
            parameters: [
                "hp.frequency": eq.bands[0].frequency,
                "hp.Q": bandwidthToQ(eq.bands[0].bandwidth),
                "lp.frequency": eq.bands[1].frequency,
                "lp.Q": bandwidthToQ(eq.bands[1].bandwidth)
            ],
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
        // Preserve the identity from the saved state so that node IDs remain
        // stable across save/load cycles. Without this, every load would give
        // every node a fresh UUID, making identity-based diffing impossible.
        id = state.id
        displayName = state.displayName
        bypass = state.bypass
        wetDryMix = min(max(state.wetDryMix, 0.0), 1.0)
        for parameter in Self.parameterCatalog {
            guard let raw = state.parameters[parameter.identifier] else { continue }
            let clamped = min(max(raw, parameter.range.lowerBound), parameter.range.upperBound)
            // Direct dispatch — avoids re-validating range.
            switch parameter.identifier {
            case "hp.frequency": eq.bands[0].frequency = clamped
            case "hp.Q": eq.bands[0].bandwidth = qToBandwidth(clamped)
            case "lp.frequency": eq.bands[1].frequency = clamped
            case "lp.Q": eq.bands[1].bandwidth = qToBandwidth(clamped)
            default: break
            }
        }
        applyMixGains()
    }

    // MARK: Q / bandwidth conversion

    /// `AVAudioUnitEQFilterParameters.bandwidth` is in octaves. The relation
    /// between Q and bandwidth (in octaves) is a standard biquad mapping:
    ///
    ///     bw = (2 / ln(2)) * asinh(1 / (2 * Q))
    ///
    /// We keep `Q` on the user-facing surface because it's the value
    /// engineers and ear-tuners think in.
    private func qToBandwidth(_ q: Float) -> Float {
        let qDouble = Double(max(q, 0.0001))
        let bw = (2.0 / log(2.0)) * asinh(1.0 / (2.0 * qDouble))
        return Float(bw)
    }

    private func bandwidthToQ(_ bandwidth: Float) -> Float {
        let bwDouble = Double(max(bandwidth, 0.0001))
        // Inverse of the formula above:
        //   sinh(bw * ln(2) / 2) = 1 / (2 * Q)
        //   Q = 1 / (2 * sinh(bw * ln(2) / 2))
        let q = 1.0 / (2.0 * sinh(bwDouble * log(2.0) / 2.0))
        return Float(q)
    }
}

/// Errors raised by `setParameter` and related dispatch.
public enum EffectParameterError: Error, Equatable {
    case unknownParameter(identifier: String)
    case valueOutOfRange(identifier: String, value: Float, range: ClosedRange<Float>)
}

/// Errors raised by `restore(from:)`.
public enum EffectRestoreError: Error, Equatable {
    case typeIdentifierMismatch(expected: String, actual: String)
    case missingExtra(key: String)
    case invalidExtra(key: String, reason: String)
}
