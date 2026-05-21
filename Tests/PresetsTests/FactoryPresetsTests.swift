import Effects
import Foundation
import Graph
import XCTest
@testable import Presets

final class FactoryPresetsTests: XCTestCase {

    func test_all_lists_both_v1_bundled_presets() {
        let names = FactoryPresets.all.map(\.name)
        XCTAssertEqual(names, ["distant-engines", "dry"])
    }

    func test_distant_engines_loads_with_expected_chain() throws {
        let preset = try FactoryPresets.load(named: "distant-engines")
        XCTAssertEqual(preset.name, "distant-engines")
        XCTAssertEqual(preset.formatVersion, 1)
        XCTAssertEqual(preset.nodes.count, 2)
        XCTAssertEqual(preset.nodes[0].typeIdentifier, "tnf.eq")
        XCTAssertEqual(preset.nodes[1].typeIdentifier, "tnf.reverb")

        // EQ's wetDryMix is 1.0 per the preset / ADR-007 rationale.
        XCTAssertEqual(preset.nodes[0].wetDryMix, 1.0, accuracy: 0.0001)
        XCTAssertEqual(preset.nodes[0].parameters["hp.frequency"], 80.0)
        XCTAssertEqual(preset.nodes[0].parameters["lp.frequency"], 800.0)

        XCTAssertEqual(preset.nodes[1].wetDryMix, 0.7, accuracy: 0.0001)
        XCTAssertEqual(preset.nodes[1].extras["preset"], .string("largeHall"))
    }

    func test_dry_loads_as_passthrough() throws {
        let preset = try FactoryPresets.load(named: "dry")
        XCTAssertEqual(preset.name, "dry")
        XCTAssertEqual(preset.nodes.count, 0)
        XCTAssertEqual(preset.outputGain, 1.0, accuracy: 0.0001)
    }

    func test_unknown_preset_throws() {
        XCTAssertThrowsError(try FactoryPresets.load(named: "missing"))
    }

    func test_distant_engines_restores_into_a_graph() throws {
        let preset = try FactoryPresets.load(named: "distant-engines")
        let graph = try Graph.restore(from: preset, using: EffectNodeRegistry())
        XCTAssertEqual(graph.nodes.count, 2)
        XCTAssertTrue(graph.lastLoadWarnings.isEmpty)

        let eq = graph.nodes[0] as? EQNode
        XCTAssertNotNil(eq)
        XCTAssertEqual(eq?.parameterValue("lp.frequency"), 800.0)

        let reverb = graph.nodes[1] as? ReverbNode
        XCTAssertNotNil(reverb)
        XCTAssertEqual(reverb?.preset, .largeHall)
    }
}
