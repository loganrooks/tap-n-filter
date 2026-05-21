import CoreAudio
import Darwin

/// A capturable audio source: a running process whose output can be intercepted
/// by a Core Audio process tap.
///
/// `CaptureSource` is intentionally a value type that bundles together the three
/// identifiers we need to talk about the same process across the OS, AppKit, and
/// the Core Audio HAL:
///
/// - `pid` is the Unix process identifier (`NSRunningApplication.processIdentifier`).
/// - `audioProcessID` is the Core Audio HAL's `AudioObjectID` representing the
///   process's audio object. The HAL takes this — not the raw `pid_t` — when
///   building a `CATapDescription`. It is resolved via
///   `kAudioHardwarePropertyTranslatePIDToProcessObject` at enumeration time and
///   may become stale if the process exits before capture starts.
/// - `bundleIdentifier` and `displayName` come from `NSRunningApplication` and
///   are used for UI presentation and for restoring a source across launches.
public struct CaptureSource: Equatable, Identifiable, Sendable {
    /// The Unix process identifier of the source application.
    public let pid: pid_t

    /// The Core Audio HAL's `AudioObjectID` representing this process's audio
    /// output object.
    ///
    /// Resolved at source-enumeration time via
    /// `kAudioHardwarePropertyTranslatePIDToProcessObject`. The value is only
    /// valid as long as the process remains known to the HAL; a stale value
    /// will cause `AudioHardwareCreateProcessTap` to fail with
    /// `kAudioHardwareBadObjectError`.
    public let audioProcessID: AudioObjectID

    /// The application's bundle identifier (e.g. `com.apple.Safari`), if any.
    /// Applications without a bundle identifier are not surfaced by
    /// `CaptureController.availableSources()`, but the field is optional so
    /// that callers reconstructing a source from persistence are not forced to
    /// invent a value.
    public let bundleIdentifier: String?

    /// A human-readable name for the source, suitable for display in UI.
    public let displayName: String

    /// `Identifiable` conformance: `pid` is unique per source within a given
    /// system run.
    public var id: pid_t { pid }

    public init(
        pid: pid_t,
        audioProcessID: AudioObjectID,
        bundleIdentifier: String?,
        displayName: String
    ) {
        self.pid = pid
        self.audioProcessID = audioProcessID
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
    }
}
