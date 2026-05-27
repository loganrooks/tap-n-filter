import AVFoundation
import AppKit
import Capture
import Combine
import CoreAudio
import Effects
import Foundation
import Graph
import OSLog
import Presets
import SwiftUI

/// Domain-level errors surfaced to the UI by `AppViewModel`.
///
/// The view model wraps capture, graph, and persistence failures into a
/// single type so the SwiftUI layer can render error state without
/// switching over disparate error namespaces.
public enum AppError: Error, Equatable {
    case capture(CaptureError)
    case graph(String)
    case parameter(String)
    case preset(String)
    case engine(String)
    case persistence(String)

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
public enum AppViewModelDefaultsKey {
    public static let graph: String = "lastSession.graph"
    public static let sourceBundleID: String = "lastSession.sourceBundleID"
    public static let debugPanel: String = "debug.enabled"
}

/// The single owner of UI state for the menubar window.
///
/// `AppViewModel` mediates between the SwiftUI views and the audio stack
/// (`Graph`, `CaptureController`, `AVAudioEngine`). It is `@MainActor` so
/// all `@Published` mutations are guaranteed to happen on the main
/// thread, which is the contract SwiftUI bindings expect.
///
/// Under the v2 (direct-IOProc + AVAudioSourceNode) architecture
/// (ADR-018), the power lifecycle is:
///
/// 1. `capture.start(source:into:)` — the controller creates the tap,
///    builds an `AVAudioSourceNode`, and attaches it to the engine. The
///    engine's `inputNode` and `outputNode` are NOT touched.
/// 2. `graph.attach(to:source:destination:)` — the view model wires the
///    effect chain from `capture.captureSourceNode` to
///    `engine.mainMixerNode`.
/// 3. `engine.prepare()` + `engine.start()`.
///
/// Power-off reverses: stop the engine, detach the graph, stop the
/// controller. `outputNode` stays on the system default device
/// throughout, which is the property that ADR-018 turned into a
/// load-bearing invariant.
@MainActor
public final class AppViewModel: ObservableObject {

    // MARK: Published state

    @Published public private(set) var graph: Graph

    @Published public var currentSource: CaptureSource?

    @Published public private(set) var availableSources: [CaptureSource] = []

    @Published public private(set) var captureState: CaptureState = .idle {
        didSet {
            if oldValue != captureState {
                logger.info("captureState: \(String(describing: oldValue)) -> \(String(describing: self.captureState))")
            }
        }
    }

    @Published public var expandedEffectID: UUID?

    @Published public private(set) var lastError: AppError? {
        didSet {
            switch (oldValue, lastError) {
            case (nil, let new?):
                logger.warning("lastError set: \(new.userMessage)")
            case (let old?, nil):
                logger.info("lastError cleared (was: \(old.userMessage))")
            case (let old?, let new?):
                logger.warning("lastError replaced: \(old.userMessage) -> \(new.userMessage)")
            case (nil, nil):
                break
            }
        }
    }

    public var availableEffectTypes: [String] {
        registry.registeredTypeIdentifiers
    }

    public let debugLog: DebugLogStore

    @Published public private(set) var showDebugPanel: Bool

    public func toggleDebugPanel() {
        showDebugPanel.toggle()
        defaults.set(showDebugPanel, forKey: AppViewModelDefaultsKey.debugPanel)
    }

    // MARK: Collaborators

    private let capture: CaptureControllerProtocol
    private let engine: AVAudioEngine
    private let registry: EffectNodeRegistry
    private let defaults: UserDefaults
    private let logger: TnfLogger

    private var stateCancellable: AnyCancellable?
    private var sourceRefreshTimer: Timer?
    private var persistenceWorkItem: DispatchWorkItem?
    private var configChangeObserver: NSObjectProtocol?
    private var refreshSourcesTask: Task<Void, Never>?
    private var sourceChangeShutdownTask: Task<Void, Never>?

    private static let persistenceDebounceInterval: TimeInterval = 0.200

    private var engineIsRunning: Bool = false

    // MARK: Init

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
        let bootstrapLogger = Logger(subsystem: "tnf.app", category: "AppViewModel.bootstrap")
        self.graph = AppViewModel.restoreGraph(from: defaults, registry: registry, logger: bootstrapLogger)

        stateCancellable = capture.statePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.captureState = state
                if case .failed(let error) = state {
                    self?.lastError = .capture(error)
                }
            }

        // Observe AVAudioEngine configuration changes for diagnostics
        // only. Under the v2 architecture the IOProc-driven capture is
        // decoupled from the engine's render pull, so the H4 detach +
        // reattach branch the original implementation needed is no
        // longer load-bearing — the source node keeps draining the ring
        // buffer through engine reconfigurations. See ADR-018.
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            let outFmt = self.engine.outputNode.outputFormat(forBus: 0)
            self.logger.info(
                "AVAudioEngineConfigurationChange fired: engine.isRunning=\(self.engine.isRunning), "
                + "outputNode=\(outFmt.sampleRate) Hz x \(outFmt.channelCount) ch"
            )
        }

        restoreSourceFromDefaults()
        refreshAvailableSources()
        startSourceRefreshTimer()
    }

    public convenience init() {
        self.init(
            capture: CaptureController(coreAudio: RealCoreAudioInterface()),
            engine: AVAudioEngine()
        )
    }

    deinit {
        sourceRefreshTimer?.invalidate()
        persistenceWorkItem?.cancel()
        refreshSourcesTask?.cancel()
        sourceChangeShutdownTask?.cancel()
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: Menubar icon

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

    public func setSource(_ source: CaptureSource?) {
        let previousSource = currentSource
        switch captureState {
        case .running:
            if sourceChangeShutdownTask == nil {
                sourceChangeShutdownTask = Task { [weak self] in
                    await self?.powerOff()
                    await MainActor.run { [weak self] in
                        self?.sourceChangeShutdownTask = nil
                    }
                }
            }
        case .starting, .stopping:
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
    /// V2 flow:
    /// 1. Resolve the source from the live HAL list (audioProcessID can
    ///    rotate between selection and start).
    /// 2. `capture.start(source:into:)` — the controller creates the
    ///    tap, builds the `AVAudioSourceNode`, attaches it to the
    ///    engine, and starts the IOProc. Audio is now pumping into the
    ///    ring buffer.
    /// 3. `graph.attach(to:source:destination:)` — wire the effect chain
    ///    from the source node into `engine.mainMixerNode`.
    /// 4. `engine.prepare()` + `engine.start()`.
    public func powerOn() async {
        guard let source = currentSource else {
            lastError = .engine("No source selected.")
            return
        }
        guard captureState == .idle || isFailedState(captureState) else {
            return
        }
        lastError = nil

        // Re-resolve the source from the live HAL list. Match by PID
        // first; bundle ID is a fallback for the relaunch-between-pick-
        // and-start case.
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

        do {
            try capture.start(source: resolvedSource, into: engine)
        } catch let error as CaptureError {
            lastError = .capture(error)
            return
        } catch {
            lastError = .engine("Capture start failed: \(error.localizedDescription)")
            return
        }

        guard let sourceNode = capture.captureSourceNode else {
            stopCaptureLoggingRollbackError(primaryStage: "captureSourceNode lookup")
            lastError = .engine("Capture started but no source node was published.")
            return
        }

        do {
            try graph.attach(
                to: engine,
                source: sourceNode,
                destination: engine.mainMixerNode
            )
        } catch {
            stopCaptureLoggingRollbackError(primaryStage: "graph attach")
            logger.error("Graph attach failed: \(error.localizedDescription) — full: \(String(describing: error))")
            lastError = .graph("Graph attach failed: \(error.localizedDescription)")
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
            let nsError = error as NSError
            let outFormat = engine.outputNode.outputFormat(forBus: 0)
            logger.error("Engine start failed: domain=\(nsError.domain) code=\(nsError.code) desc=\(error.localizedDescription)")
            logger.error("outputNode.outputFormat=\(outFormat.sampleRate) Hz × \(outFormat.channelCount) ch")
            if !nsError.userInfo.isEmpty {
                logger.error("userInfo: \(nsError.userInfo)")
            }
            lastError = .engine("Engine start failed: \(error.localizedDescription)")
            return
        }

        currentSource = resolvedSource
        schedulePersistence()
    }

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

    public func clearError() {
        lastError = nil
    }

    // MARK: Graph mutations

    public func addEffect(of typeIdentifier: String) {
        logger.info("addEffect: \(typeIdentifier) (chain size before: \(self.graph.nodes.count))")
        mutateGraph { graph in
            let node = try registry.makeNode(typeIdentifier: typeIdentifier)
            try graph.add(node)
        }
        logger.info("addEffect: complete (chain size after: \(self.graph.nodes.count))")
    }

    public func removeEffect(at index: Int) {
        logger.info("removeEffect: at index \(index) (chain size before: \(self.graph.nodes.count))")
        mutateGraph { graph in
            try graph.remove(at: index)
        }
        logger.info("removeEffect: complete (chain size after: \(self.graph.nodes.count))")
    }

    public func moveEffect(from: Int, to: Int) {
        logger.info("moveEffect: from \(from) to \(to)")
        mutateGraph { graph in
            try graph.move(from: from, to: to)
        }
    }

    public func updateParameter(nodeID: UUID, paramID: String, value: Float) {
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

    public func savePreset(to url: URL) {
        let snapshot = graph.snapshot(name: url.deletingPathExtension().lastPathComponent)
        do {
            try PresetStore.save(snapshot, to: url)
        } catch {
            lastError = .preset("Save failed: \(error.localizedDescription)")
        }
    }

    public func loadPreset(from url: URL) {
        do {
            let preset = try PresetStore.load(from: url)
            try installPreset(PresetMigrator.migrate(preset))
        } catch {
            lastError = .preset("Load failed: \(error.localizedDescription)")
        }
    }

    public func loadFactoryPreset(named name: String) {
        do {
            let preset = try FactoryPresets.load(named: name)
            try installPreset(PresetMigrator.migrate(preset))
        } catch {
            lastError = .preset("Factory preset load failed: \(error.localizedDescription)")
        }
    }

    // MARK: Internals

    /// Apply a mutation closure to the graph. If the engine is running,
    /// detach the graph for the mutation and re-attach via the same path
    /// `powerOn` uses (source node → mainMixerNode).
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
            if wasRunning {
                reattachAfterMutation()
            }
            return
        }
        objectWillChange.send()
        schedulePersistence()

        if wasRunning {
            logger.info("mutateGraph: reattaching after live mutation")
            reattachAfterMutation()
        }
    }

    /// Re-attach the graph after a live mutation and restart the engine.
    /// V2 path: the graph head is the captureSourceNode, not
    /// `engine.inputNode`.
    private func reattachAfterMutation() {
        guard let sourceNode = capture.captureSourceNode else {
            handleReattachFailure(
                NSError(
                    domain: "tnf.viewmodel",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "captureSourceNode unavailable"]
                ),
                stage: "graph attach",
                graphAttached: false
            )
            return
        }
        do {
            try graph.attach(
                to: engine,
                source: sourceNode,
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
            handleReattachFailure(error, stage: "engine start", graphAttached: true)
        }
    }

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

    /// Stop the capture controller as part of a rollback, logging any
    /// secondary error rather than discarding it.
    private func stopCaptureLoggingRollbackError(primaryStage: String) {
        do {
            try capture.stop()
        } catch {
            logger.error(
                "Rollback after \(primaryStage) failure: capture.stop also failed: \(error.localizedDescription)"
            )
        }
    }

    /// Replace the current graph with one loaded from a preset.
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
            if wasRunning {
                reattachAfterMutation()
            }
            throw error
        }
        graph = newGraph
        for warning in newGraph.lastLoadWarnings {
            logger.warning("Preset load warning: \(String(describing: warning))")
        }
        schedulePersistence()
        if wasRunning {
            reattachAfterMutation()
        }
    }

    // MARK: Persistence

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

    private func fetchAvailableSourcesOffMain() async throws -> [CaptureSource] {
        try await Task.detached(priority: .userInitiated) { [capture] in
            try capture.availableSources()
        }.value
    }

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
