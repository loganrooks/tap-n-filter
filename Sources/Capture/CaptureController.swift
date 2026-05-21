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
public final class CaptureController: CaptureControllerProtocol {

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
    private let lock = NSLock()

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
    public func start(source: CaptureSource, into engine: AVAudioEngine) throws {
        lock.lock()
        if case .running = subject.value {
            lock.unlock()
            // Idempotent: caller may re-issue start with the same source.
            return
        }
        lock.unlock()

        publish(.starting)

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
            lock.unlock()

            publish(.running(source: source))
        } catch let error as CaptureError {
            publish(.failed(error))
            throw error
        } catch {
            let wrapped = CaptureError.engineConfigurationFailed(
                "Unexpected error during start: \(error)"
            )
            publish(.failed(wrapped))
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
    public func stop() throws {
        lock.lock()
        let current = subject.value
        let resources = active
        active = nil
        lock.unlock()

        switch current {
        case .idle:
            return
        case .failed:
            // Reset to idle without throwing — the failure was already
            // surfaced to the caller. Best-effort teardown if we somehow
            // still hold resources.
            if let resources {
                _ = performTearDown(resources)
            }
            publish(.idle)
            return
        case .running, .starting, .stopping:
            break
        }

        publish(.stopping)

        guard let resources else {
            // Nothing to do; should not happen in practice but is harmless.
            publish(.idle)
            return
        }

        do {
            try tearDown(resources)
            publish(.idle)
        } catch let error as CaptureError {
            // Even on teardown error, return to idle so a fresh start can be
            // attempted. The error is reported but state does not get stuck.
            publish(.idle)
            throw error
        } catch {
            publish(.idle)
            throw CaptureError.engineConfigurationFailed(
                "Unexpected error during stop: \(error)"
            )
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

    // MARK: State publishing

    private func publish(_ newState: CaptureState) {
        subject.send(newState)
    }
}
