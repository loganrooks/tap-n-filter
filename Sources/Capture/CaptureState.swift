/// The lifecycle state of a `CaptureController`.
///
/// The state machine is intentionally explicit so the view model can present a
/// distinct UI for `starting` and `stopping` (spinner, disabled buttons) and so
/// that tests can assert on the exact transition sequence.
///
/// Transitions:
/// ```
///   idle ──start()──> starting ──> running ──stop()──> stopping ──> idle
///                          │
///                          └──── (error) ──> failed ──stop()──> idle
/// ```
public enum CaptureState: Equatable, Sendable {
    /// No tap, no aggregate device, the engine is not configured for capture.
    case idle

    /// `start()` has been called and the tap/aggregate device are being
    /// constructed. Brief — typically resolves in well under a second.
    case starting

    /// Audio is flowing from the source through the tap into the engine.
    case running(source: CaptureSource)

    /// `stop()` has been called and resources are being torn down.
    case stopping

    /// An error occurred during start or runtime. The next `stop()` returns
    /// the controller to `idle`.
    case failed(CaptureError)
}
