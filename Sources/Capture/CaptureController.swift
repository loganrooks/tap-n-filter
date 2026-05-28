import AppKit
import AVFoundation
import Combine
import CoreAudio
import Darwin
import Foundation

/// Concrete `CaptureControllerProtocol`. Owns the `TapIOProcReader` and the
/// `AVAudioSourceNode` attached to the caller's engine.
///
/// The controller's start path is the direct-IOProc + AVAudioSourceNode
/// architecture from ADR-018 / capture-v2.md:
///
/// 1. Resolve the live `audioProcessID` from the source's PID (the cached
///    ID can be stale by the time the user presses Power).
/// 2. Build a `TapIOProcReader`; it creates the tap and reads the tap's
///    stream format.
/// 3. Build an `AVAudioSourceNode` that pops frames from the reader's ring
///    on each render callback; underrun is reported as silence.
/// 4. Attach the source node to the caller's engine. The engine's
///    `inputNode` is NEVER touched; `outputNode` is left on the system
///    default. This avoids the macOS 26.3 unified-IO-AU failure mode.
/// 5. Start the reader. After this point audio is pumping into the ring;
///    the engine graph consumes from the source node once its caller
///    starts the engine.
///
/// The controller does NOT call `engine.connect` — the view model owns
/// the graph wiring. The controller only attaches the source node and
/// starts the reader.
public final class CaptureController: CaptureControllerProtocol, @unchecked Sendable {

    // MARK: State

    private let subject: CurrentValueSubject<CaptureState, Never>

    public var state: CaptureState { subject.value }

    public var statePublisher: AnyPublisher<CaptureState, Never> {
        subject.eraseToAnyPublisher()
    }

    public var captureSourceNode: AVAudioSourceNode? {
        lock.lock()
        defer { lock.unlock() }
        return active?.sourceNode
    }

    // MARK: Collaborators

    private let coreAudio: CoreAudioInterface
    private let lock = NSRecursiveLock()

    /// Diagnostic logger passed through to `TapIOProcReader`. Default is
    /// a no-op; the app's view model injects a closure that writes to
    /// both `os.Logger` and the file log so EXP-029-style diagnostic
    /// breadcrumbs survive across runs and can be diffed against the
    /// minimal-reader control.
    private let log: (String) -> Void

    /// Active capture resources. Set during `running` and cleared during
    /// `stopping`. The reader owns the tap + aggregate + IOProc; the
    /// source node owns the engine-side render block.
    private struct ActiveCapture {
        let source: CaptureSource
        let reader: TapIOProcReader
        let sourceNode: AVAudioSourceNode
        weak var engine: AVAudioEngine?
    }
    private var active: ActiveCapture?

    // MARK: Init

    public init(
        coreAudio: CoreAudioInterface = RealCoreAudioInterface(),
        log: @escaping (String) -> Void = { _ in }
    ) {
        self.coreAudio = coreAudio
        self.log = log
        self.subject = CurrentValueSubject(.idle)
    }

    // MARK: Source enumeration

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
    /// Transitions: `idle | failed` → `starting` → `running(source)`. On
    /// any failure, transitions to `failed(error)`, unwinds any
    /// partially-created resources, and re-throws.
    ///
    /// The source node is attached to the engine; `engine.connect`
    /// against the source node is the caller's responsibility (typically
    /// `AppViewModel.powerOn` wires it into the effect chain). The
    /// caller starts the engine after wiring.
    public func start(source: CaptureSource, into engine: AVAudioEngine) throws {
        if #unavailable(macOS 14.4) {
            throw CaptureError.engineConfigurationFailed("macOS 14.4 required")
        }
        lock.lock()
        let current = subject.value
        switch current {
        case .running(let activeSource):
            let sameSource = activeSource == source
            let activeEngine = active?.engine
            let sameEngine = activeEngine === engine
            lock.unlock()
            if sameSource && sameEngine {
                return
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
            log("[EXP-029.path] PRODUCTION (CaptureController.start)")
            let resolvedAudioProcessID = try coreAudio.audioProcessID(forPID: source.pid)

            // The reader owns the tap; it is the new home for tap creation,
            // tap-format probing, and the aggregate/IOProc machinery.
            let reader = try TapIOProcReader(
                audioProcessID: resolvedAudioProcessID,
                coreAudio: coreAudio,
                log: log
            )
            var didFinishSuccessfully = false
            defer {
                if !didFinishSuccessfully {
                    reader.stop()
                }
            }

            let sourceNode = AVAudioSourceNode(format: reader.format) {
                [weak ring = reader.ring] isSilence, _, frameCount, audioBufferList in
                return Self.renderFromRing(
                    ring: ring,
                    isSilence: isSilence,
                    frameCount: frameCount,
                    audioBufferList: audioBufferList
                )
            }
            log(
                "[EXP-029.engine.preattach] engine.isRunning=\(engine.isRunning) "
                + "outputFormat=\(engine.outputNode.outputFormat(forBus: 0).sampleRate)Hz×\(engine.outputNode.outputFormat(forBus: 0).channelCount)ch "
                + "inputFormat=\(engine.inputNode.outputFormat(forBus: 0).sampleRate)Hz×\(engine.inputNode.outputFormat(forBus: 0).channelCount)ch"
            )
            engine.attach(sourceNode)
            log(
                "[EXP-029.engine.postattach] engine.isRunning=\(engine.isRunning) "
                + "(attach is supposed to be lightweight; H10 hypothesis says this triggers lazy IO-AU init)"
            )
            var didAttachSourceNode = true
            defer {
                if !didFinishSuccessfully, didAttachSourceNode {
                    engine.detach(sourceNode)
                    didAttachSourceNode = false
                }
            }

            try reader.start()

            lock.lock()
            active = ActiveCapture(
                source: source,
                reader: reader,
                sourceNode: sourceNode,
                engine: engine
            )
            subject.send(.running(source: source))
            lock.unlock()
            didFinishSuccessfully = true
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
    /// From `idle` this is a no-op. From `failed`, it clears the failure
    /// and returns to `idle` without throwing. From `running`, it tears
    /// down in the reverse order of `start`: stop the reader (which
    /// destroys the IOProc, aggregate, and tap), then detach the source
    /// node from the engine.
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
                tearDown(resources)
            }
            return
        case .starting, .stopping:
            lock.unlock()
            throw CaptureError.transitionInProgress
        case .running:
            guard let resources = active else {
                active = nil
                subject.send(.idle)
                lock.unlock()
                return
            }
            subject.send(.stopping)
            lock.unlock()

            tearDown(resources)

            lock.lock()
            active = nil
            subject.send(.idle)
            lock.unlock()
        }
    }

    // MARK: Deinit cleanup

    deinit {
        if let resources = active {
            tearDown(resources)
        }
    }

    // MARK: Teardown helper

    private func tearDown(_ resources: ActiveCapture) {
        resources.reader.stop()
        if let engine = resources.engine {
            engine.detach(resources.sourceNode)
        }
    }

    // MARK: Render callback

    /// Pop frames from the ring buffer into the audio buffer list the
    /// source node was handed. On underrun, zero-fill the remainder of
    /// the destination buffers and report `isSilence`. Static so the
    /// render callback can be a non-capturing C-compatible block.
    ///
    /// `isSilence` is set on every call (not just the silent path) so a
    /// stale `true` from a prior underrun doesn't survive into a later
    /// non-empty read — `AVAudioSourceNode`'s contract is that the
    /// callback declares per-call whether the buffer it wrote is silent.
    ///
    /// Uses `withUnsafeTemporaryAllocation` for the destination-pointer
    /// scratch so the real-time render path doesn't allocate.
    private static func renderFromRing(
        ring: AudioRingBuffer?,
        isSilence: UnsafeMutablePointer<ObjCBool>,
        frameCount: AVAudioFrameCount,
        audioBufferList: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus {
        let outList = UnsafeMutableAudioBufferListPointer(audioBufferList)
        let frames = Int(frameCount)
        let bufferCount = outList.count

        return withUnsafeTemporaryAllocation(
            of: UnsafeMutablePointer<Float>.self,
            capacity: max(1, bufferCount)
        ) { scratch -> OSStatus in
            var valid = 0
            for ch in 0..<bufferCount {
                guard let raw = outList[ch].mData else { continue }
                scratch[valid] = raw.assumingMemoryBound(to: Float.self)
                valid += 1
            }

            guard let ring, valid > 0, let base = scratch.baseAddress else {
                // No ring or no destinations: emit silence.
                for i in 0..<valid {
                    memset(scratch[i], 0, frames * MemoryLayout<Float>.size)
                }
                isSilence.pointee = ObjCBool(true)
                return noErr
            }

            let framesRead = ring.read(
                intoChannelPointers: base,
                channelCount: valid,
                frames: frames
            )
            if framesRead < frames {
                let tailLength = (frames - framesRead) * MemoryLayout<Float>.size
                for i in 0..<valid {
                    memset(scratch[i].advanced(by: framesRead), 0, tailLength)
                }
            }
            isSilence.pointee = ObjCBool(framesRead == 0)
            return noErr
        }
    }
}
