import AVFoundation
import Combine

/// The public surface of the capture layer.
///
/// Pulled into its own protocol so that the rest of the app (view model,
/// `tap-n-filter` executable) can depend on the abstraction rather than
/// the concrete `CaptureController` class, which makes UI-level tests
/// trivial.
public protocol CaptureControllerProtocol: AnyObject {
    /// The current lifecycle state. Reads are non-blocking and safe from
    /// any thread.
    var state: CaptureState { get }

    /// A Combine publisher that emits on every state transition,
    /// including the current value at subscription time.
    ///
    /// Emissions arrive on whichever thread called `start` or `stop`.
    /// Subscribers that need main-thread delivery (SwiftUI bindings,
    /// AppKit-bound `@Published` properties) must attach
    /// `.receive(on: DispatchQueue.main)` before sinking.
    var statePublisher: AnyPublisher<CaptureState, Never> { get }

    /// The active `AVAudioSourceNode` attached to the engine during
    /// running, or `nil` when capture is not running. The caller uses
    /// this as the head of the effect chain when wiring the graph
    /// (`graph.attach(to:source:destination:)`).
    var captureSourceNode: AVAudioSourceNode? { get }

    /// List applications currently producing audio that can be captured.
    ///
    /// Returned sources are filtered to those that have a resolvable
    /// bundle identifier; this drops the (typically very large)
    /// population of kernel and helper processes that the HAL reports.
    func availableSources() throws -> [CaptureSource]

    /// Begin capturing from `source`, attaching an `AVAudioSourceNode`
    /// into `engine`. The engine's `inputNode` is NOT touched; the
    /// engine's `outputNode` is left on the system default output device.
    ///
    /// The caller is responsible for wiring the source node into the
    /// effect chain via `engine.connect` calls after `start` returns.
    /// See `docs/specs/capture-v2.md` for the architecture and ADR-018
    /// for the rationale.
    func start(source: CaptureSource, into engine: AVAudioEngine) throws

    /// Stop the current capture. Stops the IOProc, destroys the
    /// aggregate device, destroys the tap, detaches the source node from
    /// the engine. Safe to call from `idle` (no-op).
    func stop() throws
}
