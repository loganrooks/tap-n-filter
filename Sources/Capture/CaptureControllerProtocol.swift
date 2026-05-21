import AVFoundation
import Combine

/// The public surface of the capture layer.
///
/// Pulled into its own protocol so that the rest of the app (view model,
/// `tap-n-filter` executable) can depend on the abstraction rather than the
/// concrete `CaptureController` class, which makes UI-level tests trivial.
public protocol CaptureControllerProtocol: AnyObject {
    /// The current lifecycle state. Reads are non-blocking and safe from any
    /// thread.
    var state: CaptureState { get }

    /// A Combine publisher that emits on every state transition, including the
    /// current value at subscription time.
    ///
    /// Emissions arrive on whichever thread caused the transition — typically
    /// the thread that called `start` or `stop`, or `deinit`'s thread for
    /// cleanup. Subscribers that need main-thread delivery (SwiftUI bindings,
    /// AppKit-bound `@Published` properties) must attach
    /// `.receive(on: DispatchQueue.main)` before sinking.
    var statePublisher: AnyPublisher<CaptureState, Never> { get }

    /// List applications currently producing audio that can be captured.
    ///
    /// Returned sources are filtered to those that have a resolvable bundle
    /// identifier; this drops the (typically very large) population of
    /// kernel and helper processes that the HAL reports.
    func availableSources() throws -> [CaptureSource]

    /// Begin capturing from `source`, routing audio into `engine`. The
    /// engine's input node is reconfigured to read from the tap's aggregate
    /// device. The caller is responsible for connecting the input node to
    /// downstream nodes (mixer, effects) before calling `start`.
    func start(source: CaptureSource, into engine: AVAudioEngine) throws

    /// Stop the current capture. Releases the tap and aggregate device and
    /// resets the engine's input node to the default input device. Safe to
    /// call from `idle` (no-op).
    func stop() throws
}
