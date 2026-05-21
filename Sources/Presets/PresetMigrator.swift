import Foundation
import Graph

/// Placeholder for format-version migration logic.
///
/// V1 ships `formatVersion = 1` and there are no prior versions to migrate
/// from. The migrator exists so that when V2 bumps the format, the entry
/// point is already in the right place — the loader can call
/// `PresetMigrator.migrate(_:)` before constructing a `Graph` and the
/// migration logic is one switch statement away.
public enum PresetMigrator {

    /// Current format version this build understands.
    public static let currentFormatVersion: Int = 1

    /// Migrate `preset` forward to the current format version. V1 returns
    /// the input unchanged. Future versions will replace this with a switch
    /// over `preset.formatVersion`.
    public static func migrate(_ preset: GraphPreset) -> GraphPreset {
        // V1: no migrations exist; the format starts at version 1.
        precondition(
            preset.formatVersion <= currentFormatVersion,
            "Preset format version \(preset.formatVersion) is newer than this build supports."
        )
        return preset
    }
}
