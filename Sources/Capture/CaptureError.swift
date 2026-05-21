import CoreAudio
import Darwin

/// Errors raised by the capture layer.
///
/// All cases are `Equatable` so that tests can assert against specific error
/// values, and so that the view model can map cases to user-facing copy with a
/// `switch` rather than a string-comparison.
public enum CaptureError: Error, Equatable, Sendable {
    /// The user denied (or has not yet granted) the audio capture permission.
    case permissionDenied

    /// The OS could not resolve the given `pid_t` to a Core Audio process
    /// object. Typically this means the process is not currently producing
    /// audio, or it exited between enumeration and capture start.
    case sourceNotFound(pid_t)

    /// `AudioHardwareCreateProcessTap` returned a non-success `OSStatus`.
    case tapCreationFailed(OSStatus)

    /// `AudioHardwareCreateAggregateDevice` returned a non-success `OSStatus`.
    case aggregateDeviceCreationFailed(OSStatus)

    /// A property setter on the engine's input audio unit or some other
    /// configuration step failed. The string describes the failure for log
    /// triage; do not parse it.
    case engineConfigurationFailed(String)

    /// Running on a macOS version that does not expose the process tap API.
    case unsupportedOSVersion

    /// Capture stopped unexpectedly while running — for example the source
    /// process exited or the output device was unplugged.
    case captureInterrupted(reason: String)
}
