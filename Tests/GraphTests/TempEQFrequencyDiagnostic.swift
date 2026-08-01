import AVFoundation
import Effects
import XCTest
@testable import Graph

/// TEMPORARY diagnostic for the macos-15-only failure of
/// `GraphTests.test_snapshot_restore_roundtrip_preserves_chain`
/// (hp.frequency reads back 20.0 instead of 100.0). Prints the value at every
/// boundary so the run localises which layer loses it. Delete once the root
/// cause is identified.
final class TempEQFrequencyDiagnostic: XCTestCase {

    private func emit(_ message: String) {
        print("[DIAG] \(message)")
    }

    private func freq(_ node: EQNode?) -> String {
        String(describing: node?.parameterValue("hp.frequency"))
    }

    private func qValue(_ node: EQNode?) -> String {
        String(describing: node?.parameterValue("hp.Q"))
    }

    func test_diag_eq_frequency_boundaries() throws {
        emit("os=\(ProcessInfo.processInfo.operatingSystemVersionString)")

        // --- Layer A: fresh node defaults ---
        let eq = EQNode()
        emit("A.defaults hp.freq=\(freq(eq)) hp.Q=\(qValue(eq)) "
             + "lp.freq=\(String(describing: eq.parameterValue("lp.frequency")))")

        // --- Layer B: the AU write itself ---
        try eq.setParameter("hp.frequency", value: 100.0)
        emit("B.afterSetFrequency hp.freq=\(freq(eq))")

        // --- Layer C: does a later bandwidth write clobber frequency? ---
        try eq.setParameter("hp.Q", value: 0.707)
        emit("C.afterSetQ hp.freq=\(freq(eq)) hp.Q=\(qValue(eq))")

        // --- Layer D: what snapshot() records ---
        let state = eq.snapshot()
        emit("D.snapshot params=\(state.parameters.sorted { $0.key < $1.key })")

        // --- Layer E: the encoded JSON ---
        let graph = Graph(nodes: [eq], outputGain: 0.8)
        let preset = graph.snapshot(name: "diag")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(preset)
        emit("E.json=\(String(data: data, encoding: .utf8) ?? "<undecodable>")")

        // --- Layer F: what the decoder gives back ---
        let decoded = try JSONDecoder().decode(GraphPreset.self, from: data)
        emit("F.decoded params=\(decoded.nodes[0].parameters.sorted { $0.key < $1.key })")

        // --- Layer G: the restored node's AU readback ---
        let restored = try Graph.restore(from: decoded, using: EffectNodeRegistry())
        emit("G.restored hp.freq=\(freq(restored.nodes[0] as? EQNode)) "
             + "hp.Q=\(qValue(restored.nodes[0] as? EQNode)) "
             + "warnings=\(restored.lastLoadWarnings)")

        // --- Layer H: restore()'s exact write order on a fresh node,
        //     stepped so a clobber shows which write causes it ---
        let fresh = EQNode()
        try fresh.setParameter("hp.frequency", value: 100.0)
        emit("H1.freq hp.freq=\(freq(fresh))")
        try fresh.setParameter("hp.Q", value: 0.707)
        emit("H2.hpQ hp.freq=\(freq(fresh))")
        try fresh.setParameter("lp.frequency", value: 800.0)
        emit("H3.lpFreq hp.freq=\(freq(fresh))")
        try fresh.setParameter("lp.Q", value: 0.707)
        emit("H4.lpQ hp.freq=\(freq(fresh))")

        // --- Layer I: GraphTests' exact shape, including the ReverbNode ---
        let eqI = EQNode()
        try eqI.setParameter("hp.frequency", value: 100.0)
        let reverb = ReverbNode(preset: .mediumHall)
        reverb.wetDryMix = 0.4
        let graphI = Graph(nodes: [eqI, reverb], outputGain: 0.8)
        let presetI = graphI.snapshot(name: "test")
        emit("I1.snapshot params=\(presetI.nodes[0].parameters.sorted { $0.key < $1.key })")
        let dataI = try JSONEncoder().encode(presetI)
        let decodedI = try JSONDecoder().decode(GraphPreset.self, from: dataI)
        emit("I2.decoded params=\(decodedI.nodes[0].parameters.sorted { $0.key < $1.key })")
        let restoredI = try Graph.restore(from: decodedI, using: EffectNodeRegistry())
        emit("I3.restored hp.freq=\(freq(restoredI.nodes[0] as? EQNode))")
    }
}
