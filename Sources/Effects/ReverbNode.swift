import AVFoundation
import Foundation

/// Reverberation effect built on `AVAudioUnitReverb`'s factory presets.
///
/// The preset (a categorical choice) is held in `EffectState.extras` as a
/// stable string name. We map the string to `AVAudioUnitReverbPreset` rather
/// than serializing the raw `Int` rawValue so future SDK reorderings don't
/// break older `.tnf` files.
///
/// `wetDryMix` is implemented using the same parallel-mixer pattern as
/// `EQNode`, not the underlying `AVAudioUnitReverb.wetDryMix` parameter. Owning
/// the mix externally keeps every node's wet/dry behaviour consistent with the
/// protocol's "Wet/dry mixing convention" section. The underlying reverb unit
/// runs at 100% wet internally.
public final class ReverbNode: EffectNode {

    // MARK: Type-level metadata

    public static let typeIdentifier: String = "tnf.reverb"

    private static let defaultDisplayName: String = "Reverb"

    /// Default preset chosen to produce a noticeable but musical hall sound
    /// suitable as the ear-test baseline. Documented in the
    /// `distant-engines` preset spec.
    public static let defaultPreset: AVAudioUnitReverbPreset = .largeHall

    /// Bus index where the dry path connects on `outputBus`. Conventionally 0.
    private static let dryInputBusIndex: AVAudioNodeBus = 0

    /// Bus index where the wet path connects on `outputBus`. Conventionally 1.
    private static let wetInputBusIndex: AVAudioNodeBus = 1

    /// See `EQNode.sourceFanOutBus`: the input mixer's only output bus.
    private static let sourceFanOutBus: AVAudioNodeBus = 0

    // MARK: Instance state

    public let id: UUID
    public var displayName: String

    public var bypass: Bool {
        didSet { applyMixGains() }
    }

    public var wetDryMix: Float {
        didSet { applyMixGains() }
    }

    /// The currently-loaded factory preset. Setting it re-loads the underlying
    /// `AVAudioUnitReverb`'s preset.
    public var preset: AVAudioUnitReverbPreset {
        didSet { reverb.loadFactoryPreset(preset) }
    }

    public let inputBus: AVAudioMixerNode
    public let outputBus: AVAudioMixerNode
    private let dryMixer: AVAudioMixerNode
    /// See note on `EQNode.wetMixer`: a small trampoline mixer between the
    /// `AVAudioUnit` (which does not conform to `AVAudioMixing`) and
    /// `outputBus`.
    private let wetMixer: AVAudioMixerNode
    private let reverb: AVAudioUnitReverb

    private weak var attachedEngine: AVAudioEngine?

    // MARK: Init

    /// Convenience initializer used by the registry — produces a node in
    /// the default state.
    public convenience init() {
        self.init(preset: Self.defaultPreset)
    }

    public init(
        id: UUID = UUID(),
        displayName: String? = nil,
        bypass: Bool = false,
        wetDryMix: Float = 0.5,
        preset: AVAudioUnitReverbPreset
    ) {
        self.id = id
        self.displayName = displayName ?? Self.defaultDisplayName
        self.bypass = bypass
        self.wetDryMix = wetDryMix
        self.preset = preset
        self.inputBus = AVAudioMixerNode()
        self.outputBus = AVAudioMixerNode()
        self.dryMixer = AVAudioMixerNode()
        self.wetMixer = AVAudioMixerNode()
        self.reverb = AVAudioUnitReverb()

        // The underlying unit runs at 100% wet; the parallel mixer pattern
        // implements wet/dry externally for parity with other effect nodes.
        reverb.wetDryMix = 100.0
        reverb.loadFactoryPreset(preset)
    }

    // MARK: Parameters

    /// Reverb has no continuous parameters in V1 — the preset is the only
    /// user-tunable knob and it lives in `extras` as a categorical choice.
    public static let parameterCatalog: [EffectParameter] = []

    public var parameters: [EffectParameter] { Self.parameterCatalog }

    public func setParameter(_ identifier: String, value: Float) throws {
        throw EffectParameterError.unknownParameter(identifier: identifier)
    }

    // MARK: Attach / detach

    public func attach(to engine: AVAudioEngine) throws {
        engine.attach(inputBus)
        engine.attach(outputBus)
        engine.attach(dryMixer)
        engine.attach(wetMixer)
        engine.attach(reverb)

        let fanOut: [AVAudioConnectionPoint] = [
            AVAudioConnectionPoint(node: dryMixer, bus: 0),
            AVAudioConnectionPoint(node: reverb, bus: 0)
        ]
        engine.connect(
            inputBus,
            to: fanOut,
            fromBus: Self.sourceFanOutBus,
            format: nil
        )

        engine.connect(reverb, to: wetMixer, format: nil)
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
        engine.detach(reverb)
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
        if let dryDestination = dryMixer.destination(
            forMixer: outputBus,
            bus: Self.dryInputBusIndex
        ) {
            dryDestination.volume = dryGain
        } else {
            dryMixer.volume = dryGain
        }
        if let wetDestination = wetMixer.destination(
            forMixer: outputBus,
            bus: Self.wetInputBusIndex
        ) {
            wetDestination.volume = wetGain
        } else {
            wetMixer.volume = wetGain
        }
    }

    // MARK: Snapshot / restore

    public func snapshot() -> EffectState {
        EffectState(
            typeIdentifier: Self.typeIdentifier,
            id: id,
            displayName: displayName,
            bypass: bypass,
            wetDryMix: wetDryMix,
            parameters: [:],
            extras: [
                "preset": .string(Self.name(for: preset))
            ]
        )
    }

    public func restore(from state: EffectState) throws {
        guard state.typeIdentifier == Self.typeIdentifier else {
            throw EffectRestoreError.typeIdentifierMismatch(
                expected: Self.typeIdentifier,
                actual: state.typeIdentifier
            )
        }
        displayName = state.displayName
        bypass = state.bypass
        wetDryMix = min(max(state.wetDryMix, 0.0), 1.0)

        if let extra = state.extras["preset"] {
            switch extra {
            case .string(let name):
                guard let resolved = Self.preset(forName: name) else {
                    throw EffectRestoreError.invalidExtra(
                        key: "preset",
                        reason: "Unknown preset name '\(name)'"
                    )
                }
                preset = resolved
            case .int(let raw):
                guard let resolved = AVAudioUnitReverbPreset(rawValue: raw) else {
                    throw EffectRestoreError.invalidExtra(
                        key: "preset",
                        reason: "Reverb preset rawValue \(raw) is not a known case"
                    )
                }
                preset = resolved
            default:
                throw EffectRestoreError.invalidExtra(
                    key: "preset",
                    reason: "Expected string or int, got \(extra)"
                )
            }
        }
        applyMixGains()
    }

    // MARK: Preset name mapping

    /// The set of `AVAudioUnitReverbPreset` cases stable for V1. Add a new
    /// case here when Apple ships a new preset and we want users to be able
    /// to select it from a `.tnf` file.
    public static let supportedPresets: [(name: String, preset: AVAudioUnitReverbPreset)] = [
        ("smallRoom", .smallRoom),
        ("mediumRoom", .mediumRoom),
        ("largeRoom", .largeRoom),
        ("largeRoom2", .largeRoom2),
        ("mediumHall", .mediumHall),
        ("mediumHall2", .mediumHall2),
        ("mediumHall3", .mediumHall3),
        ("largeHall", .largeHall),
        ("largeHall2", .largeHall2),
        ("plate", .plate),
        ("mediumChamber", .mediumChamber),
        ("largeChamber", .largeChamber),
        ("cathedral", .cathedral)
    ]

    public static func name(for preset: AVAudioUnitReverbPreset) -> String {
        for entry in supportedPresets where entry.preset == preset {
            return entry.name
        }
        return "largeHall"
    }

    public static func preset(forName name: String) -> AVAudioUnitReverbPreset? {
        supportedPresets.first { $0.name == name }?.preset
    }
}
