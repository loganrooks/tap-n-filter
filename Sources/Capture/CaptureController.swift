import AppKit
import AVFoundation
import Combine
import CoreAudio
import Darwin
import Foundation

/// Concrete `CaptureControllerProtocol`. Owns the tap, the aggregate device,
/// and the lifecycle around them.
///
/// The controller is intentionally a `final class` so it can be observed by
/// reference from the view model, and so identity is preserved when the
/// controller is stored in `@StateObject`/`@EnvironmentObject` wrappers in
/// Phase 3.
///
/// State is published through a Combine `CurrentValueSubject` so that:
///
/// - SwiftUI views always see the latest value at subscription time.
/// - Tests can use `sink` plus `XCTestExpectation` to assert on transition
///   sequences without polling.
///
/// The Core Audio HAL calls are delegated to a `CoreAudioInterface`. The
/// production instance uses `RealCoreAudioInterface`; tests inject
/// `FakeCoreAudioInterface`.
public final class CaptureController: CaptureControllerProtocol, @unchecked Sendable {
    // The controller carries its own NSLock-based thread safety, so
    // @unchecked Sendable is the truthful annotation. The audit covers two
    // concerns:
    //
    //   - `subject.value` reads are atomic (CurrentValueSubject is documented
    //     to be safe from any thread).
    //   - All `active` reads/writes are guarded by `lock`.

    // MARK: State

    private let subject: CurrentValueSubject<CaptureState, Never>

    /// The current capture state. Reads are non-blocking.
    public var state: CaptureState { subject.value }

    /// Combine publisher emitting on every state transition, including the
    /// current value at subscription time. The publisher is `eraseToAnyPublisher`'d
    /// so callers can't depend on the concrete subject type.
    public var statePublisher: AnyPublisher<CaptureState, Never> {
        subject.eraseToAnyPublisher()
    }

    // MARK: Collaborators

    private let coreAudio: CoreAudioInterface
    /// Recursive so a synchronous Combine subscriber that calls back into
    /// `state` (or even `start`/`stop` — unwise but not catastrophic) cannot
    /// deadlock by re-acquiring the lock on the same thread. The cost is the
    /// usual NSRecursiveLock overhead; the alternative (release lock before
    /// publishing) opens a race window where another thread can validate
    /// state against a value we've already decided to mutate. Recursive
    /// acquisition is the simpler robust choice.
    private let lock = NSRecursiveLock()

    /// Currently active resources, set during `running` and cleared during
    /// `stopping`. Held under `lock` because the controller may be touched
    /// from both the main thread (UI) and a background task that called
    /// `start`/`stop`.
    private struct ActiveCapture {
        let source: CaptureSource
        let tapID: AudioObjectID
        let aggregateDeviceID: AudioDeviceID
        weak var engine: AVAudioEngine?
    }
    private var active: ActiveCapture?

    // MARK: Init

    /// Constructs a controller.
    ///
    /// - Parameter coreAudio: HAL adapter. Defaults to `RealCoreAudioInterface()`
    ///   in production; tests pass a `FakeCoreAudioInterface`.
    public init(coreAudio: CoreAudioInterface = RealCoreAudioInterface()) {
        self.coreAudio = coreAudio
        self.subject = CurrentValueSubject(.idle)
    }

    // MARK: Source enumeration

    /// Returns the list of capturable sources currently running.
    ///
    /// The implementation asks the HAL for all audio-active processes, then
    /// enriches each with `NSRunningApplication` metadata. Entries that
    /// cannot be matched to a running application with a bundle identifier
    /// are dropped — they're typically system helpers we don't want to expose
    /// in the UI anyway.
    public func availableSources() throws -> [CaptureSource] {
        let audioProcesses = try coreAudio.availableAudioProcesses()
        let runningApps = NSWorkspace.shared.runningApplications
        var appsByPID: [pid_t: NSRunningApplication] = [:]
        appsByPID.reserveCapacity(runningApps.count)
        for app in runningApps {
            appsByPID[app.processIdentifier] = app
        }

        var sources: [CaptureSource] = []
        sources.reserveCapacity(audioProcesses.count)
        for entry in audioProcesses {
            guard let app = appsByPID[entry.pid] else { continue }
            guard let bundleID = app.bundleIdentifier, !bundleID.isEmpty else { continue }
            let name = app.localizedName ?? bundleID
            sources.append(
                CaptureSource(
                    pid: entry.pid,
                    audioProcessID: entry.audioProcessID,
                    bundleIdentifier: bundleID,
                    displayName: name
                )
            )
        }
        return sources
    }

    // MARK: Start

    /// Begin capture from `source` into `engine`.
    ///
    /// Transitions: `idle | failed` → `starting` → `running(source)`. On any
    /// failure, transitions to `failed(error)`, unwinds any partially-created
    /// resources, and re-throws. The engine is not started here — that
    /// remains the caller's responsibility, after wiring downstream nodes.
    ///
    /// Concurrent-call behaviour:
    ///
    /// - During `.running` with the **same** source and engine: idempotent
    ///   no-op return.
    /// - During `.running` with a different source or engine: throws
    ///   `.alreadyRunning(currentSource:)`.
    /// - During `.starting` or `.stopping`: throws `.transitionInProgress`.
    public func start(source: CaptureSource, into engine: AVAudioEngine) throws {
        // Phase 1: atomic validation + transition mark. Holding the lock
        // across `subject.send(.starting)` is intentional — it ensures no
        // other thread can see `.idle` and race past the guard. Internal
        // sinks (test recorders) do not re-enter; external sinks should not
        // either, but if they do, switching to NSRecursiveLock is the
        // controlled escape hatch.
        lock.lock()
        let current = subject.value
        switch current {
        case .running(let activeSource):
            // Compare engine identity (and tolerate a weak-reference that
            // has been deallocated by treating it as a permission to bind
            // to the new engine).
            let sameSource = activeSource == source
            let activeEngine = active?.engine
            let sameEngine = activeEngine === engine
            lock.unlock()
            if sameSource && sameEngine {
                return // idempotent
            }
            throw CaptureError.alreadyRunning(currentSource: activeSource)
        case .starting, .stopping:
            lock.unlock()
            throw CaptureError.transitionInProgress
        case .idle, .failed:
            break
        }
        subject.send(.starting)
        lock.unlock()

        do {
            // Verify the HAL still recognises this source. The audioProcessID
            // we cached at enumeration time may already be stale.
            let resolvedAudioProcessID = try coreAudio.audioProcessID(forPID: source.pid)

            // Create the tap. From this point until success we keep cleanup
            // closures so partial failures don't leak Core Audio objects.
            let tapID = try coreAudio.createTap(for: resolvedAudioProcessID)
            var didFinishSuccessfully = false
            defer {
                if !didFinishSuccessfully {
                    try? coreAudio.destroyTap(tapID)
                }
            }

            // Tap UID → aggregate device. The UID must come from the tap
            // object, not from the AudioObjectID directly (which is a UInt32
            // and has no `.uid` property).
            let uid = try coreAudio.tapUID(for: tapID)
            let aggregateID = try coreAudio.createAggregateDevice(
                containing: tapID,
                uid: uid,
                sourcePID: source.pid,
                displayName: source.displayName
            )
            var didReleaseAggregateOwnership = false
            defer {
                if !didFinishSuccessfully && !didReleaseAggregateOwnership {
                    try? coreAudio.destroyAggregateDevice(aggregateID)
                }
            }

            // Wire the engine's input node to the aggregate device. After
            // this, `engine.inputNode` reads from our tap.
            try coreAudio.configureEngineInput(engine, toReadFrom: aggregateID)

            // Success — install the active capture and transition. We mark
            // both ownership transfers before publishing so the defer blocks
            // know not to tear down on the way out.
            didReleaseAggregateOwnership = true
            didFinishSuccessfully = true

            lock.lock()
            active = ActiveCapture(
                source: source,
                tapID: tapID,
                aggregateDeviceID: aggregateID,
                engine: engine
            )
            subject.send(.running(source: source))
            lock.unlock()
        } catch let error as CaptureError {
            lock.lock()
            active = nil
            subject.send(.failed(error))
            lock.unlock()
            throw error
        } catch {
            let wrapped = CaptureError.engineConfigurationFailed(
                "Unexpected error during start: \(error)"
            )
            lock.lock()
            active = nil
            subject.send(.failed(wrapped))
            lock.unlock()
            throw wrapped
        }
    }

    // MARK: Stop

    /// Stop the current capture and release HAL resources.
    ///
    /// From `idle` this is a no-op. From `failed`, it clears the failure and
    /// returns to `idle` without throwing (the caller has already been told
    /// about the error). From `running`, it tears down in the reverse order
    /// of `start`. Cleanup errors are swallowed after the first because the
    /// goal is "leave no orphaned resources" rather than "report every
    /// status code".
    ///
    /// Concurrent-call behaviour:
    ///
    /// - During `.starting` or `.stopping`: throws `.transitionInProgress`
    ///   rather than racing the in-flight transition. `active` is preserved
    ///   throughout teardown so a concurrent observer never sees the
    ///   "active is nil but state is running/stopping" inconsistency.
    public func stop() throws {
        lock.lock()
        let current = subject.value
        switch current {
        case .idle:
            lock.unlock()
            return
        case .failed:
            let resources = active
            active = nil
            subject.send(.idle)
            lock.unlock()
            if let resources {
                _ = performTearDown(resources)
            }
            return
        case .starting, .stopping:
            lock.unlock()
            throw CaptureError.transitionInProgress
        case .running:
            // Keep `active` set during teardown so concurrent observers see
            // a consistent (state, resources) pair. We copy the reference
            // for the actual HAL calls, which happen outside the lock.
            guard let resources = active else {
                // .running with no active is an internal invariant violation;
                // defensive recovery instead of crashing.
                active = nil
                subject.send(.idle)
                lock.unlock()
                return
            }
            subject.send(.stopping)
            lock.unlock()

            do {
                try tearDown(resources)
                lock.lock()
                active = nil
                subject.send(.idle)
                lock.unlock()
            } catch let error as CaptureError {
                // Even on teardown error, return to idle so a fresh start can
                // be attempted. Resources may already be partially released
                // by `performTearDown`; reset `active` to avoid double-free.
                lock.lock()
                active = nil
                subject.send(.idle)
                lock.unlock()
                throw error
            } catch {
                lock.lock()
                active = nil
                subject.send(.idle)
                lock.unlock()
                throw CaptureError.engineConfigurationFailed(
                    "Unexpected error during stop: \(error)"
                )
            }
        }
    }

    // MARK: Deinit cleanup

    /// Best-effort teardown when the controller is released while still
    /// holding HAL resources — typically because the owning view model was
    /// torn down without calling `stop()`. Without this, the tap and
    /// aggregate device would persist until process exit (and the aggregate
    /// device might survive even that).
    ///
    /// We do not take `lock` here: by definition no other strong references
    /// to `self` exist when `deinit` runs, so the only possible contender is
    /// a sink holding a `weak self` — those would observe `self` as nil
    /// before deinit completes, and would not call back into the controller.
    deinit {
        if let resources = active {
            _ = performTearDown(resources)
        }
    }

    // MARK: Teardown helpers

    /// Tear down active resources in the reverse of the start order:
    /// engine input → aggregate device → tap. Returns the first error
    /// encountered (if any). The caller decides whether to swallow or
    /// re-throw.
    private func performTearDown(_ resources: ActiveCapture) -> Error? {
        var firstError: Error?

        if let engine = resources.engine {
            do {
                try coreAudio.resetEngineInput(engine)
            } catch {
                firstError = firstError ?? error
            }
        }
        do {
            try coreAudio.destroyAggregateDevice(resources.aggregateDeviceID)
        } catch {
            firstError = firstError ?? error
        }
        do {
            try coreAudio.destroyTap(resources.tapID)
        } catch {
            firstError = firstError ?? error
        }

        return firstError
    }

    /// Throwing convenience over `performTearDown`. Used by the normal stop
    /// path; the `failed` reset path uses `performTearDown` directly and
    /// discards the error.
    private func tearDown(_ resources: ActiveCapture) throws {
        if let error = performTearDown(resources) {
            throw error
        }
    }
}
