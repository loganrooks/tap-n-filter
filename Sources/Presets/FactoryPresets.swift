import Foundation
import Graph

/// A factory preset bundled inside the app.
public struct BundledPreset: Equatable {
    /// Stable identifier; matches the file basename and the `name` field in
    /// the `.tnf` JSON. Used as the `load(named:)` key.
    public let name: String
    /// User-visible label for menus.
    public let displayName: String
    /// On-disk filename inside `Resources/Presets/`, including extension.
    public let filename: String
}

/// Errors raised by `FactoryPresets`.
public enum FactoryPresetError: Error {
    case unknownPreset(name: String)
    case bundleResourceMissing(filename: String)
    case loadFailed(filename: String, underlying: Error)
}

/// The set of `.tnf` presets bundled inside the Presets target's resource
/// bundle.
///
/// Per `docs/specs/preset-format.md`, V1 ships exactly two factory presets:
/// `distant-engines` (the motivating ambient preset) and `dry` (a passthrough
/// baseline useful for confirming wiring). Both are read from the bundle at
/// runtime — the app does not copy them to the user's writable preset
/// location.
public enum FactoryPresets {

    /// All bundled presets, ordered for display.
    public static let all: [BundledPreset] = [
        BundledPreset(
            name: "distant-engines",
            displayName: "Distant Engines",
            filename: "distant-engines.tnf"
        ),
        BundledPreset(
            name: "dry",
            displayName: "Dry",
            filename: "dry.tnf"
        )
    ]

    /// Load the named bundled preset from `Bundle.module`.
    public static func load(named name: String) throws -> GraphPreset {
        guard let bundled = all.first(where: { $0.name == name }) else {
            throw FactoryPresetError.unknownPreset(name: name)
        }
        return try load(bundled)
    }

    /// Load a specific bundled preset.
    public static func load(_ bundled: BundledPreset) throws -> GraphPreset {
        let baseName = (bundled.filename as NSString).deletingPathExtension
        let pathExtension = (bundled.filename as NSString).pathExtension
        guard let url = Bundle.module.url(
            forResource: baseName,
            withExtension: pathExtension,
            subdirectory: "Presets"
        ) else {
            throw FactoryPresetError.bundleResourceMissing(filename: bundled.filename)
        }
        do {
            return try PresetStore.load(from: url)
        } catch {
            throw FactoryPresetError.loadFailed(filename: bundled.filename, underlying: error)
        }
    }
}
