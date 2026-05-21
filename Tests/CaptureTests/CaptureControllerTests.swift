import AVFoundation
import Combine
import CoreAudio
import Darwin
import XCTest
@testable import Capture

/// Unit tests for `CaptureController`'s state machine and resource-ownership
/// behaviour. The Core Audio HAL is injected through `FakeCoreAudioInterface`
/// so these tests run on any machine without permissions or hardware
/// dependencies.
///
/// Integration tests that actually create taps live in
/// `Tests/CaptureIntegrationTests/` and are gated on `RUN_INTEGRATION_TESTS=1`.
final class CaptureControllerTests: XCTestCase {

    // MARK: Fixtures

    private let knownPID: pid_t = 5_000
    private let knownAudioProcessID: AudioObjectID = 42

    private func makeFake(withKnownSource: Bool = true) -> FakeCoreAudioInterface {
        let fake = FakeCoreAudioInterface()
        if withKnownSource {
            fake.audioProcessIDsByPID = [knownPID: knownAudioProcessID]
        }
        return fake
    }

    private func makeSource(
        pid: pid_t? = nil,
        audioProcessID: AudioObjectID? = nil
    ) -> CaptureSource {
        CaptureSource(
            pid: pid ?? knownPID,
            audioProcessID: audioProcessID ?? knownAudioProcessID,
            bundleIdentifier: "com.example.fake",
            displayName: "Fake"
        )
    }

    /// Records every state transition for a controller. Used in lieu of
    /// polling so transition-order assertions are deterministic.
    private final class StateRecorder {
        private(set) var states: [CaptureState] = []
        private var cancellables = Set<AnyCancellable>()

        init(_ controller: CaptureController) {
            controller.statePublisher
                .sink { [weak self] state in self?.states.append(state) }
                .store(in: &cancellables)
        }
    }

    // MARK: Initial state

    func test_initial_state_is_idle() {
        let controller = CaptureController(coreAudio: FakeCoreAudioInterface())
        XCTAssertEqual(controller.state, .idle)
    }

    // MARK: Start lifecycle

    func test_start_transitions_through_starting_to_running() throws {
        let fake = makeFake()
        let controller = CaptureController(coreAudio: fake)
        let recorder = StateRecorder(controller)
        let source = makeSource()
        let engine = AVAudioEngine()

        try controller.start(source: source, into: engine)

        XCTAssertEqual(controller.state, .running(source: source))
        // recorder.states[0] is the replayed current value (.idle), then
        // .starting, then .running. CurrentValueSubject emits the held value
        // at subscription time.
        XCTAssertEqual(recorder.states, [.idle, .starting, .running(source: source)])
    }

    func test_start_failure_transitions_to_failed_and_throws() {
        let fake = makeFake()
        let failure: OSStatus = -10_875 // arbitrary; treated as opaque
        fake.createTapResult = { _ in throw CaptureError.tapCreationFailed(failure) }
        let controller = CaptureController(coreAudio: fake)
        let recorder = StateRecorder(controller)
        let source = makeSource()
        let engine = AVAudioEngine()

        XCTAssertThrowsError(try controller.start(source: source, into: engine)) { error in
            XCTAssertEqual(error as? CaptureError, .tapCreationFailed(failure))
        }
        XCTAssertEqual(controller.state, .failed(.tapCreationFailed(failure)))
        XCTAssertEqual(
            recorder.states,
            [.idle, .starting, .failed(.tapCreationFailed(failure))]
        )
    }

    // MARK: Stop lifecycle

    func test_stop_from_running_transitions_through_stopping_to_idle() throws {
        let fake = makeFake()
        let controller = CaptureController(coreAudio: fake)
        let source = makeSource()
        let engine = AVAudioEngine()
        try controller.start(source: source, into: engine)

        let recorder = StateRecorder(controller)
        try controller.stop()

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(
            recorder.states,
            [.running(source: source), .stopping, .idle]
        )
        XCTAssertEqual(fake.resetEngineInputCallCount, 1)
        XCTAssertEqual(fake.destroyAggregateDeviceCallIDs.count, 1)
        XCTAssertEqual(fake.destroyTapCallIDs.count, 1)
    }

    func test_stop_from_idle_is_noop() throws {
        let fake = FakeCoreAudioInterface()
        let controller = CaptureController(coreAudio: fake)
        let recorder = StateRecorder(controller)

        try controller.stop()

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(recorder.states, [.idle])
        XCTAssertEqual(fake.resetEngineInputCallCount, 0)
        XCTAssertTrue(fake.destroyAggregateDeviceCallIDs.isEmpty)
        XCTAssertTrue(fake.destroyTapCallIDs.isEmpty)
    }

    func test_start_then_stop_then_start_works() throws {
        let fake = makeFake()
        let controller = CaptureController(coreAudio: fake)
        let source = makeSource()
        let engine = AVAudioEngine()

        try controller.start(source: source, into: engine)
        try controller.stop()
        try controller.start(source: source, into: engine)

        XCTAssertEqual(controller.state, .running(source: source))
        XCTAssertEqual(fake.createTapCallProcessIDs.count, 2)
        XCTAssertEqual(fake.createAggregateDeviceCallTapIDs.count, 2)
        XCTAssertEqual(fake.destroyAggregateDeviceCallIDs.count, 1)
        XCTAssertEqual(fake.destroyTapCallIDs.count, 1)
    }

    // MARK: Source resolution

    func test_start_with_unknown_audio_process_throws_sourceNotFound() {
        let fake = FakeCoreAudioInterface() // no entries → all PIDs unknown
        let controller = CaptureController(coreAudio: fake)
        let source = makeSource(pid: 9_999, audioProcessID: 7)
        let engine = AVAudioEngine()

        XCTAssertThrowsError(try controller.start(source: source, into: engine)) { error in
            XCTAssertEqual(error as? CaptureError, .sourceNotFound(9_999))
        }
        XCTAssertEqual(controller.state, .failed(.sourceNotFound(9_999)))
        XCTAssertTrue(fake.createTapCallProcessIDs.isEmpty)
        XCTAssertTrue(fake.createAggregateDeviceCallTapIDs.isEmpty)
    }

    // MARK: Partial-failure cleanup

    func test_tap_destroyed_when_aggregate_device_creation_fails() {
        let fake = makeFake()
        let failure: OSStatus = kAudioHardwareIllegalOperationError
        fake.createAggregateDeviceResult = { _, _, _, _ in
            throw CaptureError.aggregateDeviceCreationFailed(failure)
        }
        let controller = CaptureController(coreAudio: fake)
        let source = makeSource()
        let engine = AVAudioEngine()

        XCTAssertThrowsError(try controller.start(source: source, into: engine)) { error in
            XCTAssertEqual(error as? CaptureError, .aggregateDeviceCreationFailed(failure))
        }
        XCTAssertEqual(fake.createTapCallProcessIDs.count, 1)
        // Tap creation succeeded → tap must be destroyed during unwind.
        XCTAssertEqual(fake.destroyTapCallIDs.count, 1)
        // Aggregate device creation failed → nothing to destroy on that side.
        XCTAssertTrue(fake.destroyAggregateDeviceCallIDs.isEmpty)
    }

    // MARK: Source enumeration

    func test_available_sources_filters_to_apps_with_bundle_identifier() throws {
        let fake = FakeCoreAudioInterface()
        // Real PIDs are needed because the controller cross-references
        // NSWorkspace.shared.runningApplications. Use the test process's own
        // PID, which is guaranteed to be present and to have a bundle ID
        // (XCTest's host process or swift-testing harness).
        let selfPID = getpid()
        // Plus a guaranteed-unknown PID that must be dropped.
        let phantomPID: pid_t = 1
        fake.availableAudioProcessesResult = {
            [
                (pid: selfPID, audioProcessID: AudioObjectID(100)),
                (pid: phantomPID, audioProcessID: AudioObjectID(101)),
            ]
        }
        let controller = CaptureController(coreAudio: fake)

        let sources = try controller.availableSources()

        // The phantom PID will not be in NSWorkspace.shared.runningApplications.
        // The self PID may or may not have a bundle identifier depending on
        // how the test host is launched. We assert the weaker invariant:
        // every returned source has a non-empty bundle identifier.
        for source in sources {
            XCTAssertNotNil(source.bundleIdentifier)
            XCTAssertFalse(source.bundleIdentifier?.isEmpty ?? true)
        }
        // And: phantom PID is not present in the result.
        XCTAssertFalse(sources.contains { $0.pid == phantomPID })
    }

    // MARK: Permission denial surfacing

    func test_permission_denied_surfaces_typed_error() {
        let fake = makeFake()
        // Simulate the HAL returning the "not running" status that is the
        // observed proxy for permission denial: the tap-creation path can't
        // succeed without permission, and our adapter wraps OSStatus into
        // `permissionDenied` at the boundary.
        fake.createTapResult = { _ in throw CaptureError.permissionDenied }
        let controller = CaptureController(coreAudio: fake)
        let source = makeSource()
        let engine = AVAudioEngine()

        XCTAssertThrowsError(try controller.start(source: source, into: engine)) { error in
            XCTAssertEqual(error as? CaptureError, .permissionDenied)
        }
        XCTAssertEqual(controller.state, .failed(.permissionDenied))
    }

    // MARK: Stop from .failed clears state

    func test_stop_from_failed_returns_to_idle_without_throwing() throws {
        let fake = makeFake()
        fake.createTapResult = { _ in throw CaptureError.tapCreationFailed(-1) }
        let controller = CaptureController(coreAudio: fake)
        let source = makeSource()
        let engine = AVAudioEngine()

        XCTAssertThrowsError(try controller.start(source: source, into: engine))
        XCTAssertEqual(controller.state, .failed(.tapCreationFailed(-1)))

        try controller.stop()
        XCTAssertEqual(controller.state, .idle)
    }

    // MARK: Idempotency and source/engine mismatch guards (codex feedback)

    func test_start_while_running_same_source_and_engine_is_noop() throws {
        let fake = makeFake()
        let controller = CaptureController(coreAudio: fake)
        let source = makeSource()
        let engine = AVAudioEngine()
        try controller.start(source: source, into: engine)

        // Second start with identical args: must not call HAL again.
        try controller.start(source: source, into: engine)

        XCTAssertEqual(controller.state, .running(source: source))
        XCTAssertEqual(fake.createTapCallProcessIDs.count, 1)
        XCTAssertEqual(fake.createAggregateDeviceCallTapIDs.count, 1)
    }

    func test_start_while_running_different_source_throws_alreadyRunning() throws {
        let fake = makeFake()
        fake.audioProcessIDsByPID = [
            knownPID: knownAudioProcessID,
            6_000: 43,
        ]
        let controller = CaptureController(coreAudio: fake)
        let firstSource = makeSource()
        let engine = AVAudioEngine()
        try controller.start(source: firstSource, into: engine)

        let differentSource = CaptureSource(
            pid: 6_000,
            audioProcessID: 43,
            bundleIdentifier: "com.example.other",
            displayName: "Other"
        )
        XCTAssertThrowsError(try controller.start(source: differentSource, into: engine)) { error in
            XCTAssertEqual(error as? CaptureError, .alreadyRunning(currentSource: firstSource))
        }
        XCTAssertEqual(controller.state, .running(source: firstSource))
        // HAL still only called once — second start did not create a new tap.
        XCTAssertEqual(fake.createTapCallProcessIDs.count, 1)
    }

    func test_start_while_running_different_engine_throws_alreadyRunning() throws {
        let fake = makeFake()
        let controller = CaptureController(coreAudio: fake)
        let source = makeSource()
        let firstEngine = AVAudioEngine()
        try controller.start(source: source, into: firstEngine)

        let secondEngine = AVAudioEngine()
        XCTAssertThrowsError(try controller.start(source: source, into: secondEngine)) { error in
            XCTAssertEqual(error as? CaptureError, .alreadyRunning(currentSource: source))
        }
        XCTAssertEqual(controller.state, .running(source: source))
        XCTAssertEqual(fake.createTapCallProcessIDs.count, 1)
    }

    // MARK: Concurrent transition guards (codex feedback)

    func test_start_during_starting_throws_transitionInProgress() throws {
        let fake = makeFake()
        let inTapCreation = expectation(description: "background thread reached createTap")
        let proceedFromTap = DispatchSemaphore(value: 0)
        let startCompleted = expectation(description: "background start returned")

        fake.createTapResult = { id in
            inTapCreation.fulfill()
            proceedFromTap.wait()
            return id + 1_000
        }

        let controller = CaptureController(coreAudio: fake)
        let source = makeSource()
        let engine = AVAudioEngine()

        DispatchQueue.global(qos: .userInitiated).async {
            // Result intentionally discarded; we only need this thread to be
            // pinned inside `start` so the foreground call observes `.starting`.
            _ = try? controller.start(source: source, into: engine)
            startCompleted.fulfill()
        }

        wait(for: [inTapCreation], timeout: 5.0)
        XCTAssertEqual(controller.state, .starting)

        XCTAssertThrowsError(try controller.start(source: source, into: engine)) { error in
            XCTAssertEqual(error as? CaptureError, .transitionInProgress)
        }

        proceedFromTap.signal()
        wait(for: [startCompleted], timeout: 5.0)
    }

    func test_stop_during_starting_throws_transitionInProgress() throws {
        let fake = makeFake()
        let inTapCreation = expectation(description: "background thread reached createTap")
        let proceedFromTap = DispatchSemaphore(value: 0)
        let startCompleted = expectation(description: "background start returned")

        fake.createTapResult = { id in
            inTapCreation.fulfill()
            proceedFromTap.wait()
            return id + 1_000
        }

        let controller = CaptureController(coreAudio: fake)
        let source = makeSource()
        let engine = AVAudioEngine()

        DispatchQueue.global(qos: .userInitiated).async {
            _ = try? controller.start(source: source, into: engine)
            startCompleted.fulfill()
        }

        wait(for: [inTapCreation], timeout: 5.0)
        XCTAssertEqual(controller.state, .starting)

        XCTAssertThrowsError(try controller.stop()) { error in
            XCTAssertEqual(error as? CaptureError, .transitionInProgress)
        }

        proceedFromTap.signal()
        wait(for: [startCompleted], timeout: 5.0)
        // The in-flight start should still complete normally.
        XCTAssertEqual(controller.state, .running(source: source))
    }

    func test_stop_during_stopping_throws_transitionInProgress() throws {
        let fake = makeFake()
        let controller = CaptureController(coreAudio: fake)
        let source = makeSource()
        let engine = AVAudioEngine()
        try controller.start(source: source, into: engine)

        let inDestroyAggregate = expectation(description: "background thread reached destroyAggregateDevice")
        let proceedFromDestroy = DispatchSemaphore(value: 0)
        let stopCompleted = expectation(description: "background stop returned")

        fake.destroyAggregateDeviceResult = { _ in
            inDestroyAggregate.fulfill()
            proceedFromDestroy.wait()
        }

        DispatchQueue.global(qos: .userInitiated).async {
            _ = try? controller.stop()
            stopCompleted.fulfill()
        }

        wait(for: [inDestroyAggregate], timeout: 5.0)
        XCTAssertEqual(controller.state, .stopping)

        XCTAssertThrowsError(try controller.stop()) { error in
            XCTAssertEqual(error as? CaptureError, .transitionInProgress)
        }

        proceedFromDestroy.signal()
        wait(for: [stopCompleted], timeout: 5.0)
        XCTAssertEqual(controller.state, .idle)
    }

    // MARK: Deinit cleanup (codex feedback)

    func test_deinit_while_running_tears_down_resources() throws {
        let fake = makeFake()
        let source = makeSource()
        let engine = AVAudioEngine()

        do {
            let controller = CaptureController(coreAudio: fake)
            try controller.start(source: source, into: engine)
            XCTAssertEqual(fake.destroyTapCallIDs.count, 0)
            XCTAssertEqual(fake.destroyAggregateDeviceCallIDs.count, 0)
            // `controller` goes out of scope here; deinit must clean up.
        }

        XCTAssertEqual(fake.destroyTapCallIDs.count, 1)
        XCTAssertEqual(fake.destroyAggregateDeviceCallIDs.count, 1)
    }
}
