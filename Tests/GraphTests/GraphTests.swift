import AVFoundation
import Effects
import XCTest
@testable import Graph

final class GraphTests: XCTestCase {

    // MARK: Attach with no nodes

    func test_empty_graph_attach_passthrough() throws {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        let graph = Graph()
        XCTAssertNoThrow(
            try graph.attach(
                to: engine,
                source: player,
                destination: engine.mainMixerNode
            )
        )
        graph.detach()
    }

    // MARK: Registry

    func test_register_and_makeNode_roundtrip_for_eq() throws {
        let registry = EffectNodeRegistry()
        let node = try registry.makeNode(typeIdentifier: "tnf.eq")
        XCTAssertEqual(type(of: node).typeIdentifier, "tnf.eq")
    }

    func test_register_and_makeNode_roundtrip_for_reverb() throws {
        let registry = EffectNodeRegistry()
        let node = try registry.makeNode(typeIdentifier: "tnf.reverb")
        XCTAssertEqual(type(of: node).typeIdentifier, "tnf.reverb")
    }

    func test_unknown_type_identifier_throws() {
        let registry = EffectNodeRegistry()
        XCTAssertThrowsError(try registry.makeNode(typeIdentifier: "tnf.nonexistent")) { error in
            guard case RegistryError.unknownTypeIdentifier(let identifier) = error else {
                XCTFail("expected unknownTypeIdentifier, got \(error)")
                return
            }
            XCTAssertEqual(identifier, "tnf.nonexistent")
        }
    }

    func test_registry_lists_default_type_identifiers() {
        let registry = EffectNodeRegistry()
        XCTAssertEqual(registry.registeredTypeIdentifiers, ["tnf.eq", "tnf.reverb"])
    }

    // MARK: Snapshot / restore

    func test_snapshot_restore_roundtrip_preserves_chain() throws {
        let eq = EQNode()
        try eq.setParameter("hp.frequency", value: 100.0)
        let reverb = ReverbNode(preset: .mediumHall)
        reverb.wetDryMix = 0.4
        let graph = Graph(nodes: [eq, reverb], outputGain: 0.8)

        let preset = graph.snapshot(name: "test")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(preset)
        let decoded = try JSONDecoder().decode(GraphPreset.self, from: data)

        let restored = try Graph.restore(from: decoded, using: EffectNodeRegistry())
        XCTAssertEqual(restored.nodes.count, 2)
        XCTAssertEqual(restored.outputGain, 0.8, accuracy: 0.0001)

        let restoredEQ = restored.nodes[0] as? EQNode
        XCTAssertNotNil(restoredEQ)
        XCTAssertEqual(restoredEQ?.parameterValue("hp.frequency"), 100.0)

        let restoredReverb = restored.nodes[1] as? ReverbNode
        XCTAssertNotNil(restoredReverb)
        XCTAssertEqual(restoredReverb?.preset, .mediumHall)
        XCTAssertEqual(restoredReverb?.wetDryMix ?? 0, 0.4, accuracy: 0.0001)
    }

    func test_restore_skips_unknown_effect_with_warning() throws {
        let preset = GraphPreset(
            formatVersion: 1,
            name: "mixed",
            outputGain: 1.0,
            nodes: [
                EffectState(
                    typeIdentifier: "tnf.eq",
                    id: UUID(),
                    displayName: "EQ",
                    bypass: false,
                    wetDryMix: 1.0,
                    parameters: [:],
                    extras: [:]
                ),
                EffectState(
                    typeIdentifier: "tnf.future-effect",
                    id: UUID(),
                    displayName: "Future",
                    bypass: false,
                    wetDryMix: 1.0,
                    parameters: [:],
                    extras: [:]
                )
            ]
        )
        let graph = try Graph.restore(from: preset, using: EffectNodeRegistry())
        XCTAssertEqual(graph.nodes.count, 1)
        XCTAssertEqual(graph.lastLoadWarnings.count, 1)
        XCTAssertEqual(
            graph.lastLoadWarnings.first,
            .unknownEffect(typeIdentifier: "tnf.future-effect")
        )
    }

    // MARK: Mutations

    func test_add_remove_move_when_detached() throws {
        let graph = Graph()
        let a = EQNode()
        let b = ReverbNode()
        let c = EQNode()

        XCTAssertNoThrow(try graph.add(a))
        XCTAssertNoThrow(try graph.add(b))
        XCTAssertNoThrow(try graph.add(c, at: 1))

        XCTAssertEqual(graph.nodes.count, 3)
        XCTAssertTrue(graph.nodes[0] === a)
        XCTAssertTrue(graph.nodes[1] === c)
        XCTAssertTrue(graph.nodes[2] === b)

        XCTAssertNoThrow(try graph.move(from: 0, to: 2))
        XCTAssertTrue(graph.nodes[0] === c)
        XCTAssertTrue(graph.nodes[1] === b)
        XCTAssertTrue(graph.nodes[2] === a)

        XCTAssertNoThrow(try graph.remove(at: 1))
        XCTAssertEqual(graph.nodes.count, 2)
        XCTAssertTrue(graph.nodes[0] === c)
        XCTAssertTrue(graph.nodes[1] === a)
    }

    func test_mutations_against_attached_graph_throw() throws {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        let graph = Graph()
        try graph.attach(to: engine, source: player, destination: engine.mainMixerNode)

        XCTAssertThrowsError(try graph.add(EQNode())) { error in
            XCTAssertTrue(error is GraphError)
        }
        XCTAssertThrowsError(try graph.remove(at: 0))
        XCTAssertThrowsError(try graph.move(from: 0, to: 1))

        graph.detach()
    }

    // MARK: Attach with engine stopped — assert lifecycle (ADR-006)

    func test_attach_succeeds_on_stopped_engine() throws {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        let graph = Graph(nodes: [EQNode(), ReverbNode()])
        XCTAssertFalse(engine.isRunning)
        XCTAssertNoThrow(
            try graph.attach(
                to: engine,
                source: player,
                destination: engine.mainMixerNode
            )
        )
        graph.detach()
    }

    func test_repeat_attach_throws_alreadyAttached() throws {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        let graph = Graph()
        try graph.attach(to: engine, source: player, destination: engine.mainMixerNode)
        XCTAssertThrowsError(
            try graph.attach(to: engine, source: player, destination: engine.mainMixerNode)
        )
        graph.detach()
    }
}
