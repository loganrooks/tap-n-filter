import AVFoundation
import Effects
import Foundation

/// Errors thrown by `Graph` operations.
public enum GraphError: Error, Equatable {
    case invalidIndex(Int)
    case alreadyAttached
    case notAttached
    case engineMustBeStopped
}

/// Ordered chain of `EffectNode`s plus a post-graph output trim.
///
/// The graph is the audio side's central data structure: capture feeds it on
/// one end, the engine's main mixer reads from the other, and every effect
/// the user adds lives inside. Reordering and adding/removing nodes is
/// permitted but requires the engine to be stopped first — see ADR-006.
///
/// See `docs/specs/audio-graph.md` for the full design.
public final class Graph {

    // MARK: State

    public private(set) var nodes: [any EffectNode]

    /// Post-graph gain. Range 0.0–2.0, default 1.0. Applied via the trim
    /// mixer's output volume.
    public var outputGain: Float {
        didSet { trimMixer.outputVolume = clampedGain(outputGain) }
    }

    /// Warnings emitted by the most recent `restore(from:using:)` call.
    /// Cleared on every restore. The view model reads this immediately
    /// after restore to surface a notice to the user.
    public private(set) var lastLoadWarnings: [PresetLoadWarning] = []

    /// Mixer that applies `outputGain` between the last effect node and the
    /// destination. Owned by the graph, attached to the engine on `attach`.
    private let trimMixer: AVAudioMixerNode

    private weak var attachedEngine: AVAudioEngine?
    private weak var attachedSource: AVAudioNode?
    private weak var attachedDestination: AVAudioNode?

    // MARK: Init

    public init(nodes: [any EffectNode] = [], outputGain: Float = 1.0) {
        self.nodes = nodes
        self.outputGain = outputGain
        self.trimMixer = AVAudioMixerNode()
    }

    // MARK: Attach / detach

    /// Attach every node to `engine` and wire the chain between `source` and
    /// `destination`.
    ///
    /// Throws `GraphError.engineMustBeStopped` if the engine is running when
    /// called, enforcing the ADR-006 lifecycle invariant in both debug and
    /// release builds. (An `assert` would have been a no-op in release.)
    /// - Parameter sourceFormat: When non-nil, every connection in the
    ///   chain is pinned to this format instead of being read per-node
    ///   from `outputFormat(forBus:)`. The capture path passes the tap's
    ///   format (e.g. 48 kHz) here. This is load-bearing: an unconnected
    ///   `AVAudioSourceNode` — and an attached-but-unconnected effect
    ///   mixer — reports the engine's 44.1 kHz default from
    ///   `outputFormat(forBus:)`, not the format its render block actually
    ///   produces. Reading those defaults (the pre-fix behaviour) pinned
    ///   the whole chain to 44.1 kHz while the source produced 48 kHz
    ///   samples, so playback ran 0.919× slow — the H17 "pitched-down /
    ///   voice-changer" bug (see EXP-032 /
    ///   `docs/investigations/2026-05-audio-pipeline.md`). Pinning every
    ///   link to the capture rate makes the chain run at the source rate;
    ///   the engine's `mainMixerNode` performs the single SRC to the
    ///   output device. When nil (tests, ear-test `AVAudioPlayerNode`
    ///   whose `outputFormat` is reliable post-attach), the per-node
    ///   behaviour is preserved.
    public func attach(
        to engine: AVAudioEngine,
        source: AVAudioNode,
        destination: AVAudioNode,
        sourceFormat: AVAudioFormat? = nil
    ) throws {
        guard !engine.isRunning else {
            throw GraphError.engineMustBeStopped
        }
        if attachedEngine != nil {
            throw GraphError.alreadyAttached
        }

        // Attach the trim mixer first so we can roll back if a node throws.
        engine.attach(trimMixer)
        trimMixer.outputVolume = clampedGain(outputGain)

        var attachedNodes: [any EffectNode] = []
        do {
            for node in nodes {
                try node.attach(to: engine)
                attachedNodes.append(node)
            }
        } catch {
            // Roll back any partially-attached nodes plus the trim mixer.
            for partial in attachedNodes {
                partial.detach()
            }
            engine.detach(trimMixer)
            throw error
        }

        // Wire the chain. With zero nodes, the source goes straight into the
        // trim mixer (which then feeds destination). With one or more nodes,
        // each adjacent pair is connected and the last node's output goes
        // into the trim mixer.
        // When the caller pins an explicit format, use it for every link
        // (the chain runs uniformly at the capture rate). Otherwise fall
        // back to reading each node's negotiated output format.
        let resolvedSourceFormat = sourceFormat ?? source.outputFormat(forBus: 0)
        let pinFormat = sourceFormat != nil
        if let first = nodes.first {
            engine.connect(source, to: first.inputBus, fromBus: 0, toBus: 0, format: resolvedSourceFormat)
            for index in 0 ..< (nodes.count - 1) {
                let upstream = nodes[index]
                let downstream = nodes[index + 1]
                engine.connect(
                    upstream.outputBus,
                    to: downstream.inputBus,
                    fromBus: 0,
                    toBus: 0,
                    format: pinFormat ? resolvedSourceFormat : upstream.outputBus.outputFormat(forBus: 0)
                )
            }
            let tail = nodes.last!
            engine.connect(
                tail.outputBus,
                to: trimMixer,
                fromBus: 0,
                toBus: 0,
                format: pinFormat ? resolvedSourceFormat : tail.outputBus.outputFormat(forBus: 0)
            )
        } else {
            engine.connect(source, to: trimMixer, fromBus: 0, toBus: 0, format: resolvedSourceFormat)
        }
        engine.connect(
            trimMixer,
            to: destination,
            fromBus: 0,
            toBus: 0,
            format: pinFormat ? resolvedSourceFormat : trimMixer.outputFormat(forBus: 0)
        )

        attachedEngine = engine
        attachedSource = source
        attachedDestination = destination
    }

    /// Re-apply every node's wet/dry + bypass mix gains. Call after
    /// `engine.start()`: the per-bus mixer destinations the nodes write to are
    /// nil while the engine is stopped, so gains set during `attach` only land
    /// once the engine is running. Idempotent.
    public func refreshNodeMixState() {
        for node in nodes {
            node.refreshMixState()
        }
    }

    /// Disconnect everything wired by `attach` and call `detach()` on every
    /// node. Safe to call when not attached.
    public func detach() {
        guard let engine = attachedEngine else { return }

        // The engine's disconnect methods only require knowing the upstream
        // node; we disconnect each node's output bus, the source's output to
        // the chain, and the trim mixer's output to destination.
        if let source = attachedSource {
            engine.disconnectNodeOutput(source)
        }
        for node in nodes {
            engine.disconnectNodeOutput(node.outputBus)
            engine.disconnectNodeOutput(node.inputBus)
        }
        engine.disconnectNodeOutput(trimMixer)

        for node in nodes {
            node.detach()
        }
        engine.detach(trimMixer)

        attachedEngine = nil
        attachedSource = nil
        attachedDestination = nil
    }

    // MARK: Mutations

    /// Add `node` at `index` (defaults to end). The graph must be detached —
    /// in production, the caller stops the engine, calls `detach()`, mutates,
    /// then re-`attach`es. Mutations against an attached graph throw.
    public func add(_ node: any EffectNode, at index: Int? = nil) throws {
        try requireDetached()
        let target = index ?? nodes.count
        guard target >= 0, target <= nodes.count else {
            throw GraphError.invalidIndex(target)
        }
        nodes.insert(node, at: target)
    }

    /// Remove the node at `index`.
    public func remove(at index: Int) throws {
        try requireDetached()
        guard index >= 0, index < nodes.count else {
            throw GraphError.invalidIndex(index)
        }
        nodes.remove(at: index)
    }

    /// Move the node at `from` to `to`.
    ///
    /// `source` must be a valid index (0 ..< count). `destination` is the
    /// index in the post-removal array where the node should land; passing
    /// `nodes.count` moves the node to the end, consistent with collection
    /// reordering APIs (e.g. `List.onMove`).
    public func move(from source: Int, to destination: Int) throws {
        try requireDetached()
        guard source >= 0, source < nodes.count else {
            throw GraphError.invalidIndex(source)
        }
        // After removal the array is one shorter, so the valid insertion
        // range is 0 ... (count - 1), i.e. 0 ... (pre-removal count - 1).
        // We accept destination == nodes.count (move-to-end) before removal
        // so the caller never has to subtract 1 themselves.
        guard destination >= 0, destination <= nodes.count else {
            throw GraphError.invalidIndex(destination)
        }
        let node = nodes.remove(at: source)
        // After removal, destination may equal the new count — Array.insert
        // accepts that (it appends).
        let adjustedDestination = min(destination, nodes.count)
        nodes.insert(node, at: adjustedDestination)
    }

    /// Clamp `outputGain` to the documented 0.0–2.0 range. Values outside
    /// the range are accepted on assignment (the property is non-throwing)
    /// and clamped here at apply time, matching `wetDryMix`'s treatment.
    private func clampedGain(_ value: Float) -> Float {
        min(max(value, 0.0), 2.0)
    }

    private func requireDetached() throws {
        if let engine = attachedEngine {
            // Belt-and-braces: the caller is supposed to stop the engine
            // before mutating, but if they haven't we surface the violation.
            if engine.isRunning {
                throw GraphError.engineMustBeStopped
            }
            throw GraphError.alreadyAttached
        }
    }

    // MARK: Snapshot / restore

    /// Capture the current chain as a serializable `GraphPreset`.
    ///
    /// The returned preset's `name` defaults to `"snapshot"`. Callers that
    /// want a named preset (e.g. the UI's "Save As" flow) override the field
    /// on the returned value.
    public func snapshot(name: String = "snapshot") -> GraphPreset {
        GraphPreset(
            formatVersion: 1,
            name: name,
            outputGain: outputGain,
            nodes: nodes.map { $0.snapshot() }
        )
    }

    /// Rebuild a graph from a preset using `registry` to instantiate the
    /// concrete node types.
    ///
    /// Unknown effect types are skipped with a warning rather than thrown,
    /// per `docs/specs/preset-format.md`. Inspect `lastLoadWarnings` on the
    /// returned graph to surface a notice to the user.
    public static func restore(
        from preset: GraphPreset,
        using registry: EffectNodeRegistry
    ) throws -> Graph {
        var loadedNodes: [any EffectNode] = []
        var warnings: [PresetLoadWarning] = []

        for state in preset.nodes {
            do {
                let node = try registry.makeNode(typeIdentifier: state.typeIdentifier)
                try node.restore(from: state)
                loadedNodes.append(node)
            } catch RegistryError.unknownTypeIdentifier(let identifier) {
                warnings.append(.unknownEffect(typeIdentifier: identifier))
            } catch {
                warnings.append(
                    .nodeRestoreFailed(
                        typeIdentifier: state.typeIdentifier,
                        reason: String(describing: error)
                    )
                )
            }
        }

        // Clamp the persisted gain to the 0–2 range so the runtime value
        // always matches what the trimMixer will apply. Without this, a preset
        // written with an out-of-range value would give `outputGain` a value
        // that diverges from the clamped value used in `trimMixer.outputVolume`.
        let clampedGain = min(max(preset.outputGain, 0.0), 2.0)
        let graph = Graph(nodes: loadedNodes, outputGain: clampedGain)
        graph.lastLoadWarnings = warnings
        return graph
    }
}
