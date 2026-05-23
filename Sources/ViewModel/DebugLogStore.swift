import Foundation
import OSLog

/// File-backed sink for `TnfLogger`. Writes one line per entry to
/// `~/Library/Logs/tap-n-filter/app.log`, the standard macOS user-logs
/// location.
///
/// Why a third sink (alongside `os.Logger` and `DebugLogStore`): the OS
/// unified log persists `info`/`warning` only in memory by default —
/// reading them later via `log show` requires either `sudo log config
/// --mode persist:info ...` or capturing while the app runs. Neither
/// closes the test/review loop autonomously. A plain text log at a
/// known path lets the orchestrator read live-app diagnostics without
/// asking the user to copy-paste from the in-app debug panel.
///
/// Concurrency: a serial dispatch queue serializes writes so multiple
/// loggers can append safely from any actor. Writes are best-effort —
/// if the file or directory can't be created (sandbox-like environments,
/// read-only `~/Library/Logs`), we silently fall back to no-op rather
/// than crash the app's logging path.
public final class FileLogSink: @unchecked Sendable {
    public static let shared = FileLogSink()

    /// Resolved at init time. Public so tests and the debug panel can
    /// surface the path to the user / orchestrator.
    public let logFileURL: URL?
    private let queue = DispatchQueue(label: "tnf.app.filelogsink", qos: .utility)
    private let dateFormatter: ISO8601DateFormatter

    public init(
        directory: URL? = nil,
        filename: String = "app.log"
    ) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.dateFormatter = formatter

        let baseDir: URL
        if let directory = directory {
            baseDir = directory
        } else if let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first {
            baseDir = library.appendingPathComponent("Logs/tap-n-filter", isDirectory: true)
        } else {
            self.logFileURL = nil
            return
        }
        do {
            try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
            self.logFileURL = baseDir.appendingPathComponent(filename)
        } catch {
            // Best-effort: if we can't create the dir, file logging is
            // silently disabled. The in-app debug panel + os.Logger still
            // work, so the user-facing diagnostic story is unchanged.
            self.logFileURL = nil
        }
    }

    /// Append one entry as a line. Format:
    ///   `<ISO8601 timestamp> [<LEVEL>] <source>: <message>`
    /// Errors during the write are swallowed (best-effort).
    public func append(level: DebugLogLevel, source: String, message: String, at date: Date = Date()) {
        guard let url = logFileURL else { return }
        let line = "\(dateFormatter.string(from: date)) [\(level.rawValue.uppercased())] \(source): \(message)\n"
        let data = Data(line.utf8)
        queue.async {
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    let handle = try FileHandle(forWritingTo: url)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                } else {
                    try data.write(to: url, options: [.atomic])
                }
            } catch {
                // Best-effort; in-app panel + unified log still carry the entry.
            }
        }
    }
}

/// Severity of a `DebugLogEntry`. Mirrors `os.Logger`'s common levels so the
/// in-app debug panel reflects the same hierarchy as the unified-log output.
public enum DebugLogLevel: String, Codable, CaseIterable, Sendable {
    case info
    case warning
    case error
}

/// One line in the in-app debug log.
public struct DebugLogEntry: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let level: DebugLogLevel
    /// A short tag identifying which subsystem emitted the entry — e.g.
    /// `"AppViewModel"`, `"Capture"`. Lets the panel filter or colour by
    /// source.
    public let source: String
    public let message: String

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        level: DebugLogLevel,
        source: String,
        message: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.source = source
        self.message = message
    }
}

/// Ring buffer of recent log entries surfaced to the debug panel in the
/// menubar UI.
///
/// Why: the OS unified log (`os_log` / `Logger`) is the right place for
/// durable diagnostic output, but reading it requires `log show` from a
/// Terminal. When the user reports "press Start, nothing happens" the
/// quickest path to a diagnosis is showing them the error in the same
/// window. `DebugLogStore` keeps the last `capacity` entries in memory
/// (default 200) so the debug panel can render them as a scrollable list.
///
/// Concurrency: bound to `@MainActor`. SwiftUI observes `entries`
/// directly; mutations come from `AppViewModel` (also `@MainActor`).
/// Background work (HAL enumeration, audio callbacks) hops to the main
/// actor before calling `append`.
@MainActor
public final class DebugLogStore: ObservableObject {

    /// Newest-first list of log entries. Capped at `capacity`; older
    /// entries fall off the end on overflow.
    @Published public private(set) var entries: [DebugLogEntry] = []

    /// Maximum number of entries retained. 200 is plenty for a user
    /// session — even verbose flows produce dozens of lines, not hundreds.
    public let capacity: Int

    /// Marked `nonisolated` so the parameter default value
    /// `DebugLogStore()` in `AppViewModel.init` can be evaluated from any
    /// context — the body only assigns `let`-stored state, so there is no
    /// race with the `@MainActor`-isolated `entries` property.
    public nonisolated init(capacity: Int = 200) {
        self.capacity = max(capacity, 1)
    }

    /// Append a new entry. The matching `os.Logger` emission still goes
    /// out separately; `DebugLogStore` does not replace the unified log.
    public func append(_ entry: DebugLogEntry) {
        entries.insert(entry, at: 0)
        if entries.count > capacity {
            entries.removeLast(entries.count - capacity)
        }
    }

    /// Convenience: synthesize an entry from the parts. Sources that need
    /// a custom timestamp (e.g. tests) construct the entry directly via
    /// `init`.
    public func append(
        level: DebugLogLevel,
        source: String,
        message: String
    ) {
        append(DebugLogEntry(level: level, source: source, message: message))
    }

    /// Drop all entries. Used by tests; the UI offers a "Clear" button.
    public func clear() {
        entries.removeAll()
    }
}

/// Wrapper around `os.Logger` that also appends to a `DebugLogStore` so
/// the in-app debug panel sees every diagnostic line the unified log
/// receives. Drop-in replacement for direct `logger.info(...)` /
/// `.warning(...)` / `.error(...)` calls in `AppViewModel`.
@MainActor
public struct TnfLogger {
    private let logger: Logger
    private let store: DebugLogStore
    /// Short tag attached to every entry this logger emits. Lets the
    /// debug panel render "AppViewModel: ..." vs "Capture: ...".
    public let source: String

    public init(source: String, store: DebugLogStore, subsystem: String = "tnf.app") {
        self.source = source
        self.store = store
        self.logger = Logger(subsystem: subsystem, category: source)
    }

    public func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        store.append(level: .info, source: source, message: message)
        FileLogSink.shared.append(level: .info, source: source, message: message)
    }

    public func warning(_ message: String) {
        logger.warning("\(message, privacy: .public)")
        store.append(level: .warning, source: source, message: message)
        FileLogSink.shared.append(level: .warning, source: source, message: message)
    }

    public func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        store.append(level: .error, source: source, message: message)
        FileLogSink.shared.append(level: .error, source: source, message: message)
    }
}
