import AVFoundation
@testable import Capture
import Combine
import CoreAudio
import Darwin
import Foundation

/// Test double for `CaptureControllerProtocol`. Does not touch Core Audio or
/// the engine; transitions are driven by the test via `simulateState(_:)`.
///
/// Records calls so tests can assert behaviour: did the view model call
/// `start` once? Did it call `stop` exactly when source changed?
final class MockCaptureController: CaptureControllerProtocol, @unchecked Sendable {

    private let subject: CurrentValueSubject<CaptureState, Never>

    /// Sources to return from `availableSources()`. Override per-test.
    var availableSourcesResult: [CaptureSource] = []

    /// Error to throw from `availableSources()`. Nil = succeed.
    var availableSourcesError: CaptureError?

    /// Error to throw from `start`. Nil = succeed and transition to `.running`.
    var startError: CaptureError?

    /// Error to throw from `stop`. Nil = succeed and transition to `.idle`.
    var stopError: CaptureError?

    /// Whether `start` should auto-transition to `.running` on success. Set
    /// false to leave the controller in `.starting` for transition tests.
    var autoTransitionOnStart: Bool = true

    private(set) var startCalls: [(CaptureSource, AVAudioEngine)] = []
    private(set) var stopCallCount: Int = 0
    private(set) var availableSourcesCallCount: Int = 0

    init(initialState: CaptureState = .idle) {
        self.subject = CurrentValueSubject(initialState)
    }

    var state: CaptureState { subject.value }

    var statePublisher: AnyPublisher<CaptureState, Never> {
        subject.eraseToAnyPublisher()
    }

    /// Source node handed to the view model when capture is running. The
    /// mock creates one with a no-op render block on `start` and attaches
    /// it to the engine — same shape as the real controller — so the
    /// view model can wire the graph against a real `AVAudioNode`.
    private(set) var captureSourceNode: AVAudioSourceNode?

    func availableSources() throws -> [CaptureSource] {
        availableSourcesCallCount += 1
        if let error = availableSourcesError { throw error }
        return availableSourcesResult
    }

    func start(source: CaptureSource, into engine: AVAudioEngine) throws {
        startCalls.append((source, engine))
        if let error = startError {
            subject.send(.failed(error))
            throw error
        }
        // Mirror the real controller: create a source node and attach it
        // to the engine so the view model's graph.attach has a real
        // AVAudioNode to wire from. The render block is a no-op silence
        // generator; tests don't exercise audio rendering.
        let format = engine.outputNode.outputFormat(forBus: 0)
        let sourceNode = AVAudioSourceNode(format: format) {
            isSilence, _, _, _ in
            isSilence.pointee = ObjCBool(true)
            return noErr
        }
        engine.attach(sourceNode)
        captureSourceNode = sourceNode

        if autoTransitionOnStart {
            subject.send(.starting)
            subject.send(.running(source: source))
        } else {
            subject.send(.starting)
        }
    }

    func stop() throws {
        stopCallCount += 1
        if let error = stopError {
            throw error
        }
        captureSourceNode = nil
        subject.send(.idle)
    }

    /// Drive a state transition from the test side. Useful for verifying
    /// captureState mirroring.
    func simulateState(_ state: CaptureState) {
        subject.send(state)
    }
}
