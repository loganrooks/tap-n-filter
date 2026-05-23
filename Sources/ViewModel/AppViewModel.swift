import AVFoundation
import AppKit
import Capture
import Combine
import Effects
import Foundation
import Graph
import OSLog
import Presets
import SwiftUI

/// Domain-level errors surfaced to the UI by `AppViewModel`.
///
/// The view model wraps capture, graph, and persistence failures into a single
/// type so the SwiftUI layer can render error state without switching over
/// disparate error namespaces.
public enum AppError: Error, Equatable {
    /// Wraps a `CaptureError` raised by the capture controller.
    case capture(CaptureError)
    /// A graph mutation (add/remove/move) failed.
    case graph(String)
    /// A parameter write failed (unknown identifier, out-of-range, etc).
    case parameter(String)
    /// Preset save/load failed.
    case preset(String)
    /// Engine start/configuration failed at the AVAudioEngine layer.
    case engine(String)
    /// Persistence read/write failure (UserDefaults serialization, etc).
    case persistence(String)

    /// User-facing message rendered by the UI.
    public var userMessage: String {
        switch self {
        case .capture(let underlying):
            return AppError.message(for: underlying)
        case .graph(let reason):
            return "Graph error: \(reason)"
        case .parameter(let reason):
            return "Parameter error: \(reason)"
        case .preset(let reason):
            return "Preset error: \(reason)"
        case .engine(let reason):
            return "Engine error: \(reason)"
        case .persistence(let reason):
            return "Persistence error: \(reason)"
        }
    }

    private static func message(for error: CaptureError) -> String {
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
        case .alreadyRunning(let source):
            return "Already capturing \(source.displayName). Stop the current capture before starting a new one."
        case .transitionInProgress:
            return "Another start/stop is in progress. Please retry in a moment."
        }
    }
}

/// Keys used to persist UI session state to `UserDefaults`.
///
/// Kept as a nested enum (rather than free constants) so the keys live next to
/// the code that uses them and don't collide with other modules.
public enum AppViewModelDefaultsKey {
    public static let graph: String = "lastSession.graph"
    public static let sourceBundleID: String = "lastSession.sourceBundleID"
    public static let debugPanel: String = "debug.enabled"
}

/// The single owner of UI state for the menubar window.
///
/// `AppViewModel` mediates between the SwiftUI views and the audio stack
/// (`Graph`, `CaptureController`, `AVAudioEngine`). It is `@MainActor` so all
/// `@Published` mutations are guaranteed to happen on the main thread, which
/// is the contract SwiftUI bindings expect.
///
/// Collaborators (`capture`, `engine`, `registry`, `defaults`, `clock`,
/// `logger`) are injected so the type is unit-testable. The no-arg
/// `convenience init` wires the production defaults.
///
/// See `docs/specs/ui.md` §State management for the full surface contract.
@MainActor
public final class AppViewModel: ObservableObject {

    // MARK: Published state

    /// The audio effect chain. Mutations go through `addEffect` / `removeEffect`
    /// / `moveEffect` so persistence and engine teardown are handled centrally.
    @Published public private(set) var graph: Graph

    /// The currently selected capture source. `nil` when no source is picked.
    /// Setting this through `setSource(_:)` triggers a stop-then-stay-off
    /// transition per `docs/specs/ui.md` §SourcePickerView.
    @Published public var currentSource: CaptureSource?

    /// The list of currently capturable sources. Refreshed every 5 seconds
    /// via `sourceRefreshTimer`.
    @Published public private(set) var availableSources: [CaptureSource] = []

    /// Mirror of `capture.state`, delivered on the main thread.
    @Published public private(set) var captureState: CaptureState = .idle

    /// The UUID of the effect whose expanded controls panel is visible.
    /// Only one effect is expanded at a time, per `docs/specs/ui.md`.
    @Published public var expandedEffectID: UUID?

    /// The most recent surfaced error. Cleared on `clearError()`.
    @Published public private(set) var lastError: AppError?

    /// Effect type identifiers the injected registry can construct, in the
    /// order the registry returns them. The Add Effect menu reads this so
    /// it presents exactly the types the view model can instantiate —
    /// otherwise a non-shared registry (tests, plugin-enabled wiring) would
    /// show types the view model can't actually add and miss types it can.
    public var availableEffectTypes: [String] {
        registry.registeredTypeIdentifiers
    }

    /// In-memory ring of recent log lines. The debug panel observes this
    /// and renders the entries; every `logger.*` call here also appends to
    /// the store so the panel reflects exactly what the unified log sees.
    public let debugLog: DebugLogStore

    /// Whether the control panel renders the debug log panel below the
    /// footer. Persisted under `debug.enabled` so the user's choice
    /// survives relaunch.
    @Published public private(set) var showDebugPanel: Bool

    /// Toggle the debug-panel visibility and persist the new value.
    public func toggleDebugPanel() {
        showDebugPanel.toggle()
        defaults.set(showDebugPanel, forKey: AppViewModelDefaultsKey.debugPanel)
    }

    // MARK: Collaborators

    private let capture: CaptureControllerProtocol
    private let engine: AVAudioEngine
    private let registry: EffectNodeRegistry
    private let defaults: UserDefaults
    /// Instance logger. Writes go to the OS unified log AND the in-app
    /// `debugLog` so the debug panel can show the same lines that
    /// `log show --predicate 'subsystem == "tnf.app"'` would.
    private let logger: TnfLogger

    private var stateCancellable: AnyCancellable?
    private var sourceRefreshTimer: Timer?
    private var persistenceWorkItem: DispatchWorkItem?
    /// In-flight source refresh. Tracked so a new timer tick doesn't queue
    /// a second concurrent enumeration; HAL queries that overlap don't help
    /// the UI but do compete for the same lock inside the controller.
    private var refreshSourcesTask: Task<Void, Never>?
    /// In-flight shutdown triggered by `setSource` while running. Tracked so
    /// rapid source re-selection coalesces into a single teardown rather than
    /// queueing N concurrent `powerOff()` tasks, each of which would call
    /// `capture.stop()` and race against the controller's state machine.
    private var sourceChangeShutdownTask: Task<Void, Never>?

    /// Debounce interval for `UserDefaults` writes; 200 ms keeps slider drags
    /// from hammering the disk.
    private static let persistenceDebounceInterval: TimeInterval = 0.200

    /// Maximum time `powerOn` waits for `engine.outputNode.outputFormat`
    /// to become valid (non-zero sample rate AND channel count) before
    /// `engine.start()`. The output device can transiently report
    /// `0 Hz × 0 ch` during route changes triggered by tap creation /
    /// muting — Bluetooth audio devices are the typical offender. 1.5 s
    /// is generous; observed delays are typically under 200 ms once the
    /// route settles.
    private static let outputHardwareFormatWaitTimeout: TimeInterval = 1.5
    private static let outputHardwareFormatPollNanoseconds: UInt64 = 50_000_000

    /// Whether the engine is currently running (and therefore the graph is
    /// attached). Tracked so we know whether to tear down on `powerOff`.
    private var engineIsRunning: Bool = false

    // MARK: Init

    /// Designated initializer. Injects every collaborator so tests can swap
    /// concrete capture/engine/registry instances.
    ///
    /// On construction the view model:
    /// 1. Restores the last graph from `defaults` (falling back to
    ///    `distant-engines` on missing/corrupt data).
    /// 2. Subscribes to the capture state publisher.
    /// 3. Kicks off the source refresh timer.
    public init(
        capture: CaptureControllerProtocol,
        engine: AVAudioEngine,
        registry: EffectNodeRegistry = .shared,
        defaults: UserDefaults = .standard,
        debugLog: DebugLogStore = DebugLogStore()
    ) {
        self.capture = capture
        self.engine = engine
        self.registry = registry
        self.defaults = defaults
        self.debugLog = debugLog
        self.showDebugPanel = defaults.bool(forKey: AppViewModelDefaultsKey.debugPanel)
        self.logger = TnfLogger(source: "AppViewModel", store: debugLog)
        // The static restoreGraph uses its own os.Logger; the lines it
        // emits are app-startup only and don't need to surface in the
        // debug panel (which is unmounted until the user opens it).
        let bootstrapLogger = Logger(subsystem: "tnf.app", category: "AppViewModel.bootstrap")
        self.graph = AppViewModel.restoreGraph(from: defaults, registry: registry, logger: bootstrapLogger)

        // Capture state subscription is set up after init so the closure can
        // safely refer to self. The CurrentValueSubject delivers the current
        // value at subscription time, so captureState is populated immediately.
        stateCancellable = capture.statePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.captureState = state
                if case .failed(let error) = state {
                    self?.lastError = .capture(error)
                }
            }

        restoreSourceFromDefaults()
        refreshAvailableSources()
        startSourceRefreshTimer()
    }

    /// Convenience initializer using the production capture controller and a
    /// fresh `AVAudioEngine`. Used by `tap-n-filter`'s `@main` entry point.
    public convenience init() {
        self.init(
            capture: CaptureController(coreAudio: RealCoreAudioInterface()),
            engine: AVAudioEngine()
        )
    }

    deinit {
        // Capture local references because deinit cannot touch @MainActor
        // state. The timer is invalidated and the work item cancelled on the
        // best-effort principle: it's fine if a queued refresh fires after
        // deinit because the closure holds `weak self`.
        sourceRefreshTimer?.invalidate()
        persistenceWorkItem?.cancel()
        refreshSourcesTask?.cancel()
        sourceChangeShutdownTask?.cancel()
    }

    // MARK: Menubar icon

    /// System symbol name shown in the menubar, derived from `captureState`.
    /// Computed (not stored) so SwiftUI re-renders the icon whenever
    /// `captureState` changes via `@Published`.
    public var menuBarIconName: String {
        switch captureState {
        case .running:
            return "waveform.path"
        case .failed:
            return "waveform.path.badge.minus"
        case .idle, .starting, .stopping:
            return "waveform"
        }
    }

    // MARK: Source selection

    /// Set the active capture source.
    ///
    /// When the capture is currently `.running`, this powers the chain off
    /// first per `docs/specs/ui.md` §SourcePickerView — V1 leaves the user
    /// to press Power again rather than auto-restart, to avoid surprise. The
    /// `currentSource` is then updated and persisted.
    public func setSource(_ source: CaptureSource?) {
        let previousSource = currentSource
        switch captureState {
        case .running:
            // Coalesce. If a shutdown task from a prior source change is
            // already in flight (or about to fire), don't queue a second one
            // — capture.stop() is idempotent in design but a second concurrent
            // call still races the controller's state transitions and can
            // surface a spurious .transitionInProgress error.
            if sourceChangeShutdownTask == nil {
                sourceChangeShutdownTask = Task { [weak self] in
                    await self?.powerOff()
                    await MainActor.run { [weak self] in
                        self?.sourceChangeShutdownTask = nil
                    }
                }
            }
        case .starting, .stopping:
            // A transition is in flight; setting the source while we wait is
            // safe — controller.start will be called with the new source on
            // the next powerOn().
            break
        case .idle, .failed:
            break
        }
        currentSource = source
        if source?.bundleIdentifier != previousSource?.bundleIdentifier {
            schedulePersistence()
        }
    }

    // MARK: Power lifecycle

    /// Begin capture and engine for the current source.
    ///
    /// The lifecycle matches the production pattern established by
    /// `Phase1DebugViewModel`:
    /// 1. Enumerate sources off-main via `Task.detached` (the HAL list can
    ///    stall the UI).
    /// 2. Confirm the chosen source is still available.
    /// 3. Attach the graph to the engine BEFORE starting the engine — the
    ///    graph wiring touches `engine.inputNode`'s format, which is only
    ///    valid after `controller.start` configures the aggregate device.
    /// 4. Call `controller.start` and `engine.start` on the main actor.
    /// 5. Tear down on any failure.
    public func powerOn() async {
        guard let source = currentSource else {
            lastError = .engine("No source selected.")
            return
        }
        guard captureState == .idle || isFailedState(captureState) else {
            // Already running or transitioning — no-op.
            return
        }
        lastError = nil

        // Re-resolve the source from the live HAL list so the audioProcessID
        // we use is fresh. Match by PID first — that's what the picker keys on
        // and what uniquely identifies the running process. Fall back to
        // bundleIdentifier only if the PID is gone AND the saved source had a
        // non-empty bundle ID (e.g. the source app was killed and relaunched
        // between selection and start). Without the non-empty guard, a saved
        // source with nil bundleIdentifier (CoreAudio processes without an
        // owning app bundle) would match the first unrelated candidate that
        // also has nil — capturing the wrong process silently.
        let resolvedSource: CaptureSource
        do {
            let candidates = try await Task.detached(priority: .userInitiated) { [capture] in
                try capture.availableSources()
            }.value
            let matchByPID = candidates.first(where: { $0.pid == source.pid })
            let matchByBundleID: CaptureSource?
            if let bundleID = source.bundleIdentifier, !bundleID.isEmpty {
                matchByBundleID = candidates.first(where: { $0.bundleIdentifier == bundleID })
            } else {
                matchByBundleID = nil
            }
            guard let match = matchByPID ?? matchByBundleID else {
                lastError = .capture(.sourceNotFound(source.pid))
                return
            }
            resolvedSource = match
        } catch {
            if let captureError = error as? CaptureError {
                lastError = .capture(captureError)
            } else {
                lastError = .engine("Source enumeration failed: \(error.localizedDescription)")
            }
            return
        }

        // controller.start configures the engine's input node; the graph
        // attach must happen AFTER the input format is known, so we run them
        // in the order start → attach → engine.start.
        do {
            try capture.start(source: resolvedSource, into: engine)
        } catch let error as CaptureError {
            lastError = .capture(error)
            return
        } catch {
            lastError = .engine("Capture start failed: \(error.localizedDescription)")
            return
        }

        // Pre-empt AVAudioEngine's lazy auto-wire of
        // `inputNode → mainMixerNode.bus 0`. The engine creates that wire
        // the first time anything touches mainMixerNode and the user has
        // no way to disable it; without removing it we end up with a
        // parallel passthrough alongside our chain. The chain's processed
        // signal would land on a higher bus of mainMixerNode and get
        // summed with the untouched input — the user hears the original
        // audio with a faint processed copy mixed in, not the filtered
        // chain output the V1 design promises. Reference: the failing
        // listen test on 2026-05-21 against Safari + `distant-engines`.
        //
        // Touch mainMixerNode to force its lazy creation, then disconnect
        // any outputs from inputNode the auto-wire installed. graph.attach
        // re-establishes the explicit wiring as inputNode's only output.
        _ = engine.mainMixerNode
        engine.disconnectNodeOutput(engine.inputNode)

        do {
            // Route into the engine's main mixer, not directly into the
            // output node. The mainMixerNode is what AVAudioEngine connects
            // to outputNode automatically; bypassing it (as we did until
            // 2026-05-21) means the chain's audio never reaches the audio
            // device — the user hears only the source app's untouched
            // signal because the process tap is non-blocking. The Phase 1
            // architecture diagram explicitly puts mainMixerNode in the
            // path, and `tap-n-filter-eartest` follows the same convention
            // for offline rendering.
            try graph.attach(
                to: engine,
                source: engine.inputNode,
                destination: engine.mainMixerNode
            )
        } catch {
            stopCaptureLoggingRollbackError(primaryStage: "graph attach")
            logger.error("Graph attach failed: \(error.localizedDescription) — full: \(String(describing: error))")
            lastError = .graph("Graph attach failed: \(error.localizedDescription)")
            return
        }

        // Wait for the output device's hardware format to become valid
        // before `engine.start()`. Bluetooth headphones and other devices
        // that go through a route change when the process tap engages
        // can briefly report `0 Hz × 0 ch`, which makes
        // `IsFormatSampleRateAndChannelCountValid(outputHWFormat)` fail
        // and engine.start throw `-10875` (FailedInitialization). The
        // wait is bounded; if the format never recovers we surface a
        // typed error rather than hang.
        do {
            try await waitForValidOutputHardwareFormat()
        } catch let waitError {
            graph.detach()
            stopCaptureLoggingRollbackError(primaryStage: "output format wait")
            let outFormat = engine.outputNode.outputFormat(forBus: 0)
            logger.error("Output hardware format never became valid within \(Self.outputHardwareFormatWaitTimeout)s: \(outFormat.sampleRate) Hz × \(outFormat.channelCount) ch")
            lastError = .engine("Output device not ready: \(waitError.localizedDescription)")
            return
        }
        engine.prepare()

        do {
            try engine.start()
            engineIsRunning = true
            let chainSummary = graph.nodes.isEmpty
                ? "EMPTY (audio passes through unprocessed; add effects to hear filtering)"
                : graph.nodes.map { type(of: $0).typeIdentifier }.joined(separator: " -> ")
            logger.info("powerOn complete: engine started, capture running on \(resolvedSource.displayName), chain: \(chainSummary)")
        } catch {
            graph.detach()
            stopCaptureLoggingRollbackError(primaryStage: "engine start")
            // Engine start failures are often AVAudioEngineConfigurationException
            // from a downstream node's format mismatch, or a hardware-format
            // condition on the output device (Bluetooth handshake, sample-rate
            // contention). Dump as much as we can read so the debug panel
            // shows the actual cause, not just "engine start failed".
            let nsError = error as NSError
            let inFormat = engine.inputNode.inputFormat(forBus: 0)
            let outFormat = engine.outputNode.outputFormat(forBus: 0)
            logger.error("Engine start failed: domain=\(nsError.domain) code=\(nsError.code) desc=\(error.localizedDescription)")
            logger.error("inputNode.inputFormat=\(inFormat.sampleRate) Hz × \(inFormat.channelCount) ch, outputNode.outputFormat=\(outFormat.sampleRate) Hz × \(outFormat.channelCount) ch")
            if !nsError.userInfo.isEmpty {
                logger.error("userInfo: \(nsError.userInfo)")
            }
            lastError = .engine("Engine start failed: \(error.localizedDescription)")
            return
        }

        currentSource = resolvedSource
        schedulePersistence()
    }

    /// Stop capture and engine, returning to `.idle`. Safe to call from any
    /// state; transitions in progress are awaited implicitly via the
    /// capture controller's lifecycle.
    public func powerOff() async {
        if engineIsRunning {
            engine.stop()
            graph.detach()
            engineIsRunning = false
        }
        do {
            try capture.stop()
        } catch let error as CaptureError {
            lastError = .capture(error)
        } catch {
            lastError = .engine("Capture stop failed: \(error.localizedDescription)")
        }
    }

    /// Clear the latest surfaced error. Used by the Retry button on the
    /// PowerToggle, which returns the UI to `.idle` after a failure.
    public func clearError() {
        lastError = nil
    }

    // MARK: Graph mutations

    /// Append a fresh effect of the given type to the chain.
    ///
    /// If the engine is running, the graph is detached first, mutated, and
    /// re-attached — per ADR-006 mutations require the graph to be detached.
    /// The engine itself stays running across the transition; the audio will
    /// briefly hiccup as the chain is re-wired.
    public func addEffect(of typeIdentifier: String) {
        logger.info("addEffect: \(typeIdentifier) (chain size before: \(self.graph.nodes.count))")
        mutateGraph { graph in
            let node = try registry.makeNode(typeIdentifier: typeIdentifier)
            try graph.add(node)
        }
        logger.info("addEffect: complete (chain size after: \(self.graph.nodes.count))")
    }

    /// Remove the effect at `index` from the chain.
    public func removeEffect(at index: Int) {
        logger.info("removeEffect: at index \(index) (chain size before: \(self.graph.nodes.count))")
        mutateGraph { graph in
            try graph.remove(at: index)
        }
        logger.info("removeEffect: complete (chain size after: \(self.graph.nodes.count))")
    }

    /// Move the effect at `from` to `to`, using SwiftUI `List.onMove`'s
    /// post-removal indexing convention.
    public func moveEffect(from: Int, to: Int) {
        logger.info("moveEffect: from \(from) to \(to)")
        mutateGraph { graph in
            try graph.move(from: from, to: to)
        }
    }

    /// Update a single parameter on a node.
    ///
    /// This method does not throttle. Continuous UI controls (sliders, knobs)
    /// throttle their writes upstream via Combine before calling here; see
    /// `EffectControlsView.ParameterSlider` for the 30 Hz `throttle(...)` that
    /// keeps the AVAudioUnit parameter setter from being hammered. Discrete
    /// controls (Stepper, Picker) and one-shot loads (preset restore) don't
    /// need throttling. A future high-frequency caller must own its own
    /// throttling at the input layer.
    public func updateParameter(nodeID: UUID, paramID: String, value: Float) {
        // Short ID for log readability; full UUID stays in the lookup.
        let shortID = String(nodeID.uuidString.prefix(8))
        guard let node = graph.nodes.first(where: { $0.id == nodeID }) else {
            logger.warning("updateParameter: unknown node \(shortID) (param \(paramID)=\(value))")
            lastError = .parameter("Unknown node \(nodeID).")
            return
        }
        do {
            try node.setParameter(paramID, value: value)
            logger.info("updateParameter: \(type(of: node).typeIdentifier)/\(shortID) \(paramID)=\(value)")
            schedulePersistence()
        } catch {
            logger.error("updateParameter: \(type(of: node).typeIdentifier)/\(shortID) \(paramID)=\(value) failed: \(error.localizedDescription)")
            lastError = .parameter(error.localizedDescription)
        }
    }

    /// Set the wet/dry mix for a node. Lives outside `updateParameter` because
    /// `wetDryMix` is a protocol-level property rather than a catalog entry.
    public func updateWetDryMix(nodeID: UUID, value: Float) {
        let shortID = String(nodeID.uuidString.prefix(8))
        guard let node = graph.nodes.first(where: { $0.id == nodeID }) else {
            logger.warning("updateWetDryMix: unknown node \(shortID) (value \(value))")
            lastError = .parameter("Unknown node \(nodeID).")
            return
        }
        let clamped = min(max(value, 0.0), 1.0)
        node.wetDryMix = clamped
        logger.info("updateWetDryMix: \(type(of: node).typeIdentifier)/\(shortID) wetDryMix=\(clamped)")
        objectWillChange.send()
        schedulePersistence()
    }

    /// Toggle the bypass for a node.
    public func setBypass(nodeID: UUID, bypass: Bool) {
        guard let node = graph.nodes.first(where: { $0.id == nodeID }) else {
            lastError = .parameter("Unknown node \(nodeID).")
            return
        }
        node.bypass = bypass
        objectWillChange.send()
        schedulePersistence()
    }

    // MARK: Presets

    /// Save the current graph snapshot to `url` as a `.tnf` preset.
    public func savePreset(to url: URL) {
        let snapshot = graph.snapshot(name: url.deletingPathExtension().lastPathComponent)
        do {
            try PresetStore.save(snapshot, to: url)
        } catch {
            lastError = .preset("Save failed: \(error.localizedDescription)")
        }
    }

    /// Load a preset from `url`, replacing the current graph.
    public func loadPreset(from url: URL) {
        do {
            let preset = try PresetStore.load(from: url)
            try installPreset(PresetMigrator.migrate(preset))
        } catch {
            lastError = .preset("Load failed: \(error.localizedDescription)")
        }
    }

    /// Load one of the factory presets bundled with the app.
    public func loadFactoryPreset(named name: String) {
        do {
            let preset = try FactoryPresets.load(named: name)
            try installPreset(PresetMigrator.migrate(preset))
        } catch {
            lastError = .preset("Factory preset load failed: \(error.localizedDescription)")
        }
    }

    // MARK: Internals

    /// Apply a mutation closure to a fresh graph instance. Detaches the live
    /// graph if attached, runs the mutation, and re-attaches if the engine
    /// was running. This keeps the ADR-006 invariant (graph mutations require
    /// detached graph) without exposing the dance to callers.
    private func mutateGraph(_ mutation: (Graph) throws -> Void) {
        let wasRunning = engineIsRunning
        logger.info("mutateGraph: wasRunning=\(wasRunning)")
        if engineIsRunning {
            engine.stop()
            graph.detach()
            engineIsRunning = false
            logger.info("mutateGraph: detached for live mutation")
        }
        do {
            try mutation(graph)
        } catch {
            logger.error("mutateGraph: mutation failed: \(error.localizedDescription)")
            lastError = .graph(error.localizedDescription)
            // Re-attach if we were running; the chain is unchanged.
            if wasRunning {
                attemptReattach()
            }
            return
        }
        // Tell SwiftUI to re-render; Graph itself is a reference type so its
        // mutations don't trigger @Published.
        objectWillChange.send()
        schedulePersistence()

        if wasRunning {
            logger.info("mutateGraph: reattaching after live mutation")
            attemptReattach()
        }
    }

    /// Poll `engine.outputNode.outputFormat(forBus: 0)` until it reports
    /// a non-zero sample rate AND channel count, or `timeout` elapses.
    /// The audio route can be in a transient state right after tap
    /// creation / muting (especially on Bluetooth output devices); the
    /// poll lets the route settle without blocking the caller forever.
    private func waitForValidOutputHardwareFormat(
        timeout: TimeInterval = AppViewModel.outputHardwareFormatWaitTimeout,
        pollNanoseconds: UInt64 = AppViewModel.outputHardwareFormatPollNanoseconds
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var iterations = 0
        while true {
            let format = engine.outputNode.outputFormat(forBus: 0)
            if format.sampleRate > 0, format.channelCount > 0 {
                if iterations > 0 {
                    logger.info("Output hardware format became valid after \(iterations) poll(s): \(format.sampleRate) Hz × \(format.channelCount) ch")
                }
                return
            }
            if Date() >= deadline {
                throw CaptureError.engineConfigurationFailed(
                    "Output hardware format never became valid (timeout \(timeout)s): "
                    + "\(format.sampleRate) Hz × \(format.channelCount) ch"
                )
            }
            iterations += 1
            try await Task.sleep(nanoseconds: pollNanoseconds)
        }
    }

    /// Stop the capture controller as part of a rollback, logging any
    /// secondary error rather than discarding it. The primary failure
    /// (graph attach / engine start) is the actionable signal the user
    /// sees; the stop error is supplemental but worth preserving for
    /// diagnostics — leaked taps and partial HAL state look very different
    /// from clean teardown in the log stream.
    private func stopCaptureLoggingRollbackError(primaryStage: String) {
        do {
            try capture.stop()
        } catch {
            logger.error(
                "Rollback after \(primaryStage) failure: capture.stop also failed: \(error.localizedDescription)"
            )
        }
    }

    /// Best-effort re-attach of the graph and engine after a mutation. Errors
    /// here are surfaced through `lastError` and the capture controller is
    /// stopped, so a failed re-attach leaves the UI in a coherent idle state
    /// rather than "running" with no audio path.
    ///
    /// The attach and engine-start steps run in separate `do/catch` blocks
    /// because the cleanup is asymmetric: if `attach` fails the graph is
    /// already detached, but if `engine.start` fails the graph IS attached
    /// and we have to call `graph.detach()` ourselves before transitioning
    /// out of running — otherwise the next attach call hits `requireDetached`
    /// and throws.
    private func attemptReattach() {
        // Same auto-wire-removal dance as powerOn: AVAudioEngine re-creates
        // the inputNode → mainMixerNode passthrough whenever a connection
        // to mainMixerNode is established. Without removing it, the
        // reattached chain would compete with a parallel passthrough.
        _ = engine.mainMixerNode
        engine.disconnectNodeOutput(engine.inputNode)
        do {
            try graph.attach(
                to: engine,
                source: engine.inputNode,
                destination: engine.mainMixerNode
            )
        } catch {
            handleReattachFailure(error, stage: "graph attach", graphAttached: false)
            return
        }
        do {
            try engine.start()
            engineIsRunning = true
        } catch {
            // attach succeeded above; we MUST detach before falling out so
            // the graph is back to a state where the next reattach can run.
            handleReattachFailure(error, stage: "engine start", graphAttached: true)
        }
    }

    /// Common cleanup for `attemptReattach` failure paths. Detaches the graph
    /// if the caller indicates it succeeded in attaching, stops capture, and
    /// surfaces the original failure to the user via `lastError`.
    private func handleReattachFailure(_ error: Error, stage: String, graphAttached: Bool) {
        if graphAttached {
            graph.detach()
        }
        do {
            try capture.stop()
        } catch let stopError {
            logger.error("capture.stop after reattach \(stage) failure also failed: \(stopError.localizedDescription)")
        }
        logger.error("Re-attach \(stage) failed after graph mutation: \(error.localizedDescription) — full error: \(String(describing: error))")
        lastError = .engine("Re-attach failed after graph mutation: \(error.localizedDescription)")
    }

    /// Replace the current graph with one loaded from a preset. The engine is
    /// stopped (if running), the new graph is installed, and the engine is
    /// re-attached so capture continues against the new chain. If
    /// `Graph.restore` throws, we re-attach the original (still-held) graph
    /// so a failed preset load does not silently kill live audio.
    private func installPreset(_ preset: GraphPreset) throws {
        let wasRunning = engineIsRunning
        if engineIsRunning {
            engine.stop()
            graph.detach()
            engineIsRunning = false
        }
        let newGraph: Graph
        do {
            newGraph = try Graph.restore(from: preset, using: registry)
        } catch {
            // Restore the prior chain so audio resumes; the user sees the
            // load error via the caller's catch, but the engine isn't left
            // half-torn-down.
            if wasRunning {
                attemptReattach()
            }
            throw error
        }
        graph = newGraph
        for warning in newGraph.lastLoadWarnings {
            logger.warning("Preset load warning: \(String(describing: warning))")
        }
        schedulePersistence()
        if wasRunning {
            attemptReattach()
        }
    }

    // MARK: Persistence

    /// Restore the persisted graph from `defaults`, or fall back to the
    /// `distant-engines` factory preset on missing/corrupt data.
    private static func restoreGraph(
        from defaults: UserDefaults,
        registry: EffectNodeRegistry,
        logger: Logger
    ) -> Graph {
        if let data = defaults.data(forKey: AppViewModelDefaultsKey.graph) {
            do {
                let preset = try JSONDecoder().decode(GraphPreset.self, from: data)
                let migrated = PresetMigrator.migrate(preset)
                return try Graph.restore(from: migrated, using: registry)
            } catch {
                logger.warning("Failed to decode lastSession.graph; falling back to distant-engines: \(error.localizedDescription, privacy: .public)")
            }
        } else {
            logger.info("No lastSession.graph in UserDefaults; falling back to distant-engines.")
        }
        return restoreDistantEngines(registry: registry, logger: logger)
    }

    /// Last-resort fallback: load the bundled `distant-engines` preset. If
    /// even that fails (bundle missing, JSON malformed) returns an empty
    /// graph so the UI still renders.
    private static func restoreDistantEngines(
        registry: EffectNodeRegistry,
        logger: Logger
    ) -> Graph {
        do {
            let preset = try FactoryPresets.load(named: "distant-engines")
            return try Graph.restore(from: preset, using: registry)
        } catch {
            logger.error("Failed to load distant-engines fallback; returning empty graph: \(error.localizedDescription, privacy: .public)")
            return Graph()
        }
    }

    /// Restore `currentSource` from the persisted bundle ID, matching it
    /// against the live source list. If the saved bundle ID is no longer
    /// running, `currentSource` stays nil.
    ///
    /// HAL enumeration can stall the UI (see `powerOn` for the analogous
    /// off-main pattern), so we run it on a detached task and write back
    /// on the main actor. The write is guarded: if the user (or a test)
    /// has already set `currentSource` while the async enumeration was in
    /// flight, leave their choice alone — restore is best-effort, not
    /// authoritative.
    private func restoreSourceFromDefaults() {
        guard let bundleID = defaults.string(forKey: AppViewModelDefaultsKey.sourceBundleID),
              !bundleID.isEmpty
        else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let candidates = try await self.fetchAvailableSourcesOffMain()
                guard self.currentSource == nil else {
                    self.logger.info("Skipping restore for \(bundleID): currentSource already set.")
                    return
                }
                if let match = candidates.first(where: { $0.bundleIdentifier == bundleID }) {
                    self.currentSource = match
                }
            } catch {
                self.logger.warning("Source restore failed: \(error.localizedDescription)")
            }
        }
    }

    /// Run `capture.availableSources()` on a detached task so the HAL
    /// enumeration (which can block) does not stall the UI. Returns to the
    /// caller's actor with the result.
    private func fetchAvailableSourcesOffMain() async throws -> [CaptureSource] {
        try await Task.detached(priority: .userInitiated) { [capture] in
            try capture.availableSources()
        }.value
    }

    /// Schedule a debounced write of the current state to `UserDefaults`.
    /// Coalesces rapid mutations (slider drags) into a single write.
    private func schedulePersistence() {
        persistenceWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.writePersistence()
        }
        persistenceWorkItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.persistenceDebounceInterval,
            execute: item
        )
    }

    /// Serialize and write the current state. Run on the main actor (via the
    /// scheduled work item) because we touch `@Published` properties.
    private func writePersistence() {
        let snapshot = graph.snapshot(name: "lastSession")
        do {
            let data = try JSONEncoder().encode(snapshot)
            defaults.set(data, forKey: AppViewModelDefaultsKey.graph)
        } catch {
            logger.error("Failed to encode graph for persistence: \(error.localizedDescription)")
        }
        if let bundleID = currentSource?.bundleIdentifier {
            defaults.set(bundleID, forKey: AppViewModelDefaultsKey.sourceBundleID)
        } else {
            defaults.removeObject(forKey: AppViewModelDefaultsKey.sourceBundleID)
        }
    }

    // MARK: Source refresh

    /// Refresh `availableSources` from the capture controller.
    ///
    /// Public so the view can request an immediate refresh on appear; the
    /// timer also calls this every 5 seconds. HAL enumeration runs on a
    /// detached task so the periodic refresh does not freeze the menubar
    /// UI under load. If a refresh is already in flight, the new tick is
    /// dropped — overlapping enumerations buy nothing and waste CPU.
    public func refreshAvailableSources() {
        guard refreshSourcesTask == nil || refreshSourcesTask?.isCancelled == true else {
            return
        }
        refreshSourcesTask = Task { @MainActor [weak self] in
            defer { self?.refreshSourcesTask = nil }
            do {
                let sources = try await self?.fetchAvailableSourcesOffMain() ?? []
                self?.availableSources = sources
            } catch {
                self?.logger.warning("Source refresh failed: \(error.localizedDescription)")
            }
        }
    }

    private func startSourceRefreshTimer() {
        sourceRefreshTimer?.invalidate()
        // Timer is not `Sendable` on Swift 5.10, but @MainActor confines us to
        // the main thread so the closure is safe.
        sourceRefreshTimer = Timer.scheduledTimer(
            withTimeInterval: 5.0,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAvailableSources()
            }
        }
    }

    private func isFailedState(_ state: CaptureState) -> Bool {
        if case .failed = state { return true }
        return false
    }
}
