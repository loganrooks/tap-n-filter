import Effects
import Foundation

/// Non-fatal issues surfaced when loading a preset.
///
/// Per `docs/specs/preset-format.md`, the loader is best-effort: unknown
/// effect types and out-of-range parameters are recovered from with a warning
/// rather than thrown. The view model is expected to surface these to the
/// user as a non-blocking notice.
public enum PresetLoadWarning: Equatable {
    case unknownEffect(typeIdentifier: String)
    case nodeRestoreFailed(typeIdentifier: String, reason: String)
}

/// On-disk shape of a `.tnf` preset.
///
/// `GraphPreset` is the single Codable boundary between disk and the in-memory
/// `Graph`. Both directions of translation live on `Graph` (`snapshot()` and
/// `restore(from:using:)`). Keeping the `Codable` derivation on the value type
/// means `JSONEncoder`/`JSONDecoder` work without bespoke machinery.
public struct GraphPreset: Codable, Equatable {

    /// Format version. V1 ships version 1; future schema changes increment
    /// this and add a `PresetMigrator` entry.
    public let formatVersion: Int

    /// User-visible preset name.
    public let name: String

    /// Post-graph trim. Range 0.0–2.0, default 1.0.
    public let outputGain: Float

    /// Ordered effect chain.
    public let nodes: [EffectState]

    public init(
        formatVersion: Int = 1,
        name: String,
        outputGain: Float,
        nodes: [EffectState]
    ) {
        self.formatVersion = formatVersion
        self.name = name
        self.outputGain = outputGain
        self.nodes = nodes
    }
}
