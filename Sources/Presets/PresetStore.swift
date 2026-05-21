import Foundation
import Graph

/// Errors raised by `PresetStore`.
public enum PresetStoreError: Error {
    case fileNotFound(URL)
    case invalidJSON(URL, underlying: Error)
    case unsupportedFormatVersion(Int)
    case writeFailed(URL, underlying: Error)
}

/// File I/O for `.tnf` presets.
///
/// `PresetStore` is intentionally an enum with only static methods — there is
/// no state to hold. JSON encoding uses pretty-printed, sorted-key output so
/// the on-disk form is hand-editable and diffs cleanly under version control,
/// matching the `.tnf` format's "intentionally human-readable" goal.
public enum PresetStore {

    /// Read and decode a `.tnf` file.
    ///
    /// Throws `PresetStoreError.fileNotFound` if the URL does not resolve,
    /// `PresetStoreError.invalidJSON` if the contents fail to decode, and
    /// `PresetStoreError.unsupportedFormatVersion` if the file targets a
    /// format newer than this build understands. The loader does not throw
    /// on per-node mismatches; those are warnings surfaced by
    /// `Graph.restore`.
    public static func load(from url: URL) throws -> GraphPreset {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PresetStoreError.fileNotFound(url)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw PresetStoreError.fileNotFound(url)
        }
        return try decode(data, source: url)
    }

    /// Decode preset bytes without touching the filesystem. Useful for
    /// bundled assets read out of `Bundle.module`.
    public static func decode(_ data: Data, source: URL) throws -> GraphPreset {
        let decoder = JSONDecoder()
        do {
            let preset = try decoder.decode(GraphPreset.self, from: data)
            guard preset.formatVersion <= 1 else {
                throw PresetStoreError.unsupportedFormatVersion(preset.formatVersion)
            }
            return preset
        } catch let error as PresetStoreError {
            throw error
        } catch {
            throw PresetStoreError.invalidJSON(source, underlying: error)
        }
    }

    /// Encode `preset` and write it to `url` atomically.
    public static func save(_ preset: GraphPreset, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(preset)
        } catch {
            throw PresetStoreError.writeFailed(url, underlying: error)
        }
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            throw PresetStoreError.writeFailed(url, underlying: error)
        }
    }
}
