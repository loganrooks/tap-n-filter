import AVFoundation
import Capture
import Combine
import Foundation
import SwiftUI

// MARK: - Phase1DebugViewModel

/// View model for the Phase 1 debug UI.
///
/// Owns a `CaptureController` and an `AVAudioEngine` for the lifetime of the
/// menu-bar window. Exposes `@Published` state for SwiftUI binding.
///
/// # Manual passthrough test procedure (Phase 1 gate criterion 2)
///
/// This view model contains the code path needed for the 5-second passthrough
/// test. To run it:
///
/// 1. Open Safari and start a YouTube video (or any audio-producing tab).
/// 2. Launch the app. The menu-bar icon appears.
/// 3. Click the icon, type `com.apple.Safari` in the Bundle ID field (it is
///    the default), and click **Start**.
/// 4. Wait 5 seconds. You should hear the captured audio through your default
///    output device.
/// 5. Click **Stop**.
/// 6. If `recordOutput` is enabled (the "Record output" toggle is on), the
///    engine's mixer output was written to
///    `~/Library/Application Support/tap-n-filter/phase-1-passthrough.wav`.
///    Commit that file to `test-artifacts/phase-1-passthrough.wav` and write
///    `docs/audits/verification/phase-1-passthrough.md` recording the session.
///
/// The permission grant dialog appears on the first **Start** press. Deny it
/// to verify the `.permissionDenied` error path; allow it to run the
/// passthrough. If you denied, go to System Settings → Privacy & Security and
/// re-grant access before retrying.
@MainActor
final class Phase1DebugViewModel: ObservableObject {

    // MARK: Published state

    /// The bundle identifier the user typed. Used by `start()` to pick a source.
    @Published var bundleID: String = "com.apple.Safari"

    /// Human-readable description of the current `CaptureState`.
    @Published var statusText: String = "Idle"

    /// `true` while a capture is running; controls button enable/disable.
    @Published var isRunning: Bool = false

    /// `true` while the controller is not running and not in the middle of a
    /// start/stop transition; controls button enable/disable.
    @Published var isIdle: Bool = true

    /// `true` when the last failure was `.permissionDenied`. Drives the
    /// "Open System Settings" link.
    @Published var isPermissionDenied: Bool = false

    /// When `true`, the engine's `mainMixerNode` output is recorded to
    /// `~/Library/Application Support/tap-n-filter/phase-1-passthrough.wav`
    /// during the capture session. Toggle before pressing Start.
    @Published var recordOutput: Bool = false

    // MARK: Private collaborators

    private let controller: CaptureController
    private let engine: AVAudioEngine
    private var stateCancellable: AnyCancellable?

    /// Non-nil while we're writing the output wav.
    private var outputFile: AVAudioFile?

    // MARK: Init

    init() {
        self.controller = CaptureController(coreAudio: RealCoreAudioInterface())
        self.engine = AVAudioEngine()

        // Subscribe to controller state on the main actor so @Published
        // mutations always happen on the main thread.
        stateCancellable = controller.statePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.apply(state)
            }
    }

    // MARK: Actions

    /// Start capture for the bundle ID currently in `bundleID`.
    ///
    /// Enumerates available sources, finds the first whose `bundleIdentifier`
    /// matches `bundleID`, and calls `controller.start(source:into:)`. If no
    /// match is found the status line reflects the failure.
    ///
    /// Source enumeration hops off the main actor via `Task.detached` so the
    /// HAL's `kAudioHardwarePropertyProcessObjectList` lookup doesn't stall
    /// the menu bar. `controller.start(source:into:)` and `engine.start()`
    /// stay on the main actor because `controller.start` calls into
    /// `configureEngineInput`, which mutates `engine.inputNode.audioUnit` —
    /// AVAudioEngine is not Sendable, and AVFoundation guidance is to
    /// configure the engine serially on a single thread.
    ///
    /// The codex P2 "run blocking capture startup off main actor" finding
    /// is partly deferred: enumeration moves off main here; the permission
    /// prompt is a system modal so the brief UI stall while it appears is
    /// acceptable. Phase 3's real UI will split HAL prep from engine binding
    /// so the full pipeline can run off main.
    func start() {
        let bundleIDSnapshot = bundleID
        let shouldRecord = recordOutput
        let captureController = controller

        Task {
            // Step 1: enumerate sources off the main actor.
            let enumeration: Result<[CaptureSource], Error>
            do {
                let sources = try await Task.detached(priority: .userInitiated) {
                    try captureController.availableSources()
                }.value
                enumeration = .success(sources)
            } catch {
                enumeration = .failure(error)
            }

            let sources: [CaptureSource]
            switch enumeration {
            case .success(let result):
                sources = result
            case .failure(let error):
                applyStartError(error)
                return
            }

            guard let source = sources.first(where: { $0.bundleIdentifier == bundleIDSnapshot }) else {
                // Reset isPermissionDenied so stale red status from a prior
                // failure doesn't survive an unrelated lookup miss.
                isPermissionDenied = false
                statusText = "No audio source found for \"\(bundleIDSnapshot)\". Is the app producing audio?"
                return
            }

            // Step 2: install recording tap on main (engine touch).
            var didInstallRecordingTap = false
            if shouldRecord {
                installRecordingTap()
                didInstallRecordingTap = (outputFile != nil)
            }

            // Step 3: controller.start on main. controller.start calls
            // configureEngineInput which mutates engine.inputNode.audioUnit;
            // staying on main keeps AVAudioEngine touches single-threaded.
            do {
                try controller.start(source: source, into: engine)
            } catch {
                if didInstallRecordingTap { removeRecordingTap() }
                applyStartError(error)
                return
            }

            // Step 4: engine wiring + start on main. If engine.start() throws,
            // roll back the controller and remove the recording tap so
            // resources don't leak past the failed start. A rollback that
            // also throws is surfaced to the user — silently swallowing it
            // hides leaked tap/aggregate-device resources.
            do {
                let inputFormat = engine.inputNode.outputFormat(forBus: 0)
                engine.connect(engine.inputNode, to: engine.mainMixerNode, format: inputFormat)
                engine.connect(engine.mainMixerNode, to: engine.outputNode, format: inputFormat)
                try engine.start()
            } catch {
                var rollbackError: Error?
                do {
                    try controller.stop()
                } catch {
                    rollbackError = error
                }
                if didInstallRecordingTap { removeRecordingTap() }
                if let rollbackError {
                    isPermissionDenied = false
                    statusText = "Engine start failed (\(error.localizedDescription)); rollback also failed (\(rollbackError.localizedDescription)). HAL resources may be leaked — restart the app."
                } else {
                    applyStartError(error)
                }
            }
        }
    }

    /// Apply a typed or untyped start error to the published status.
    /// `isPermissionDenied` is set exactly once per call: `true` only for
    /// `.permissionDenied`, otherwise `false`. This avoids the stale-flag
    /// bug where the permission link could remain visible after an
    /// unrelated failure.
    private func applyStartError(_ error: Error) {
        if let captureError = error as? CaptureError {
            statusText = userMessage(for: captureError)
            isPermissionDenied = (captureError == .permissionDenied)
        } else {
            isPermissionDenied = false
            statusText = "Unexpected error: \(error.localizedDescription)"
        }
    }

    /// Stop the current capture and clean up the engine.
    ///
    /// Runs on the main actor because `controller.stop()` internally calls
    /// `resetEngineInput`, which mutates `engine.inputNode.audioUnit`.
    /// AVAudioEngine teardown is single-threaded by AVFoundation guidance.
    func stop() {
        Task {
            engine.stop()
            engine.disconnectNodeOutput(engine.inputNode)
            engine.disconnectNodeOutput(engine.mainMixerNode)
            removeRecordingTap()

            do {
                try controller.stop()
            } catch let error as CaptureError {
                statusText = userMessage(for: error)
            } catch {
                statusText = "Stop error: \(error.localizedDescription)"
            }
        }
    }

    // MARK: State application

    private func apply(_ state: CaptureState) {
        switch state {
        case .idle:
            statusText = "Idle"
            isRunning = false
            isIdle = true
            isPermissionDenied = false
        case .starting:
            statusText = "Starting…"
            isRunning = false
            isIdle = false
            isPermissionDenied = false
        case .running(let source):
            statusText = "Running — capturing \(source.displayName)"
            isRunning = true
            isIdle = false
            isPermissionDenied = false
        case .stopping:
            statusText = "Stopping…"
            isRunning = false
            isIdle = false
            isPermissionDenied = false
        case .failed(let error):
            statusText = userMessage(for: error)
            isRunning = false
            isIdle = true
            isPermissionDenied = (error == .permissionDenied)
        }
    }

    // MARK: User-friendly error messages

    private func userMessage(for error: CaptureError) -> String {
        switch error {
        case .permissionDenied:
            return "Permission denied. Grant access in System Settings → Privacy & Security."
        case .sourceNotFound(let pid):
            return "Source not found (PID \(pid)). Is the app producing audio?"
        case .tapCreationFailed(let status):
            return "Tap creation failed (OSStatus \(status))."
        case .aggregateDeviceCreationFailed(let status):
            return "Aggregate device creation failed (OSStatus \(status))."
        case .engineConfigurationFailed(let reason):
            return "Engine configuration failed: \(reason)"
        case .unsupportedOSVersion:
            return "macOS 14.4 or later is required."
        case .captureInterrupted(let reason):
            return "Capture interrupted: \(reason)"
        case .alreadyRunning(let currentSource):
            return "Already capturing \(currentSource.displayName). Stop the current capture before starting a new one."
        case .transitionInProgress:
            return "Another start/stop is in progress. Please retry in a moment."
        }
    }

    // MARK: Output recording (opt-in)

    /// Installs an AVAudioEngine tap on `mainMixerNode` that writes PCM frames
    /// to a wav file at
    /// `~/Library/Application Support/tap-n-filter/phase-1-passthrough.wav`.
    ///
    /// Call before `engine.start()`. The tap is removed by `removeRecordingTap()`.
    private func installRecordingTap() {
        let mixerFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        guard let outputURL = recordingOutputURL() else {
            statusText = "Warning: could not resolve output file path; recording disabled."
            return
        }
        do {
            outputFile = try AVAudioFile(
                forWriting: outputURL,
                settings: mixerFormat.settings,
                commonFormat: mixerFormat.commonFormat,
                interleaved: mixerFormat.isInterleaved
            )
            let file = outputFile  // capture for the closure
            engine.mainMixerNode.installTap(
                onBus: 0,
                bufferSize: 4096,
                format: mixerFormat
            ) { [weak file] buffer, _ in
                try? file?.write(from: buffer)
            }
        } catch {
            statusText = "Warning: could not open recording file (\(error.localizedDescription)); recording disabled."
            outputFile = nil
        }
    }

    /// Removes the recording tap and closes the output file.
    private func removeRecordingTap() {
        engine.mainMixerNode.removeTap(onBus: 0)
        outputFile = nil
    }

    /// Returns the URL for the recording output file, creating the containing
    /// directory if needed.
    private func recordingOutputURL() -> URL? {
        guard
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
        else { return nil }

        let dir = appSupport.appendingPathComponent("tap-n-filter", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: nil
        )
        return dir.appendingPathComponent("phase-1-passthrough.wav")
    }
}
