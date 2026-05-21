import Effects
import Foundation
import Graph
import XCTest
@testable import Presets

final class PresetStoreTests: XCTestCase {

    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("tap-n-filter-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: tempDirectory)
    }

    // MARK: Round-trip

    func test_save_then_load_roundtrips_a_preset() throws {
        let preset = GraphPreset(
            formatVersion: 1,
            name: "test",
            outputGain: 0.5,
            nodes: [
                EffectState(
                    typeIdentifier: "tnf.eq",
                    id: UUID(),
                    displayName: "EQ",
                    bypass: false,
                    wetDryMix: 1.0,
                    parameters: ["hp.frequency": 80.0, "lp.frequency": 800.0],
                    extras: [:]
                )
            ]
        )
        let url = tempDirectory.appendingPathComponent("test.tnf")
        try PresetStore.save(preset, to: url)
        let loaded = try PresetStore.load(from: url)
        XCTAssertEqual(loaded, preset)
    }

    func test_save_writes_pretty_printed_sorted_JSON() throws {
        let preset = GraphPreset(
            formatVersion: 1,
            name: "test",
            outputGain: 1.0,
            nodes: []
        )
        let url = tempDirectory.appendingPathComponent("test.tnf")
        try PresetStore.save(preset, to: url)
        let contents = try String(contentsOf: url, encoding: .utf8)
        // Pretty-printed JSON contains newlines; sorted keys put
        // formatVersion before name, name before nodes, etc.
        XCTAssertTrue(contents.contains("\n"))
        XCTAssertTrue(contents.contains("\"formatVersion\""))
        let formatVersionIndex = contents.range(of: "formatVersion")!.lowerBound
        let nameIndex = contents.range(of: "\"name\"")!.lowerBound
        XCTAssertLessThan(formatVersionIndex, nameIndex)
    }

    // MARK: Failure modes

    func test_load_throws_on_missing_file() {
        let url = tempDirectory.appendingPathComponent("not-there.tnf")
        XCTAssertThrowsError(try PresetStore.load(from: url)) { error in
            guard case PresetStoreError.fileNotFound = error else {
                XCTFail("Expected fileNotFound, got \(error)")
                return
            }
        }
    }

    func test_load_throws_on_invalid_JSON() throws {
        let url = tempDirectory.appendingPathComponent("garbage.tnf")
        try "this is not JSON".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try PresetStore.load(from: url)) { error in
            guard case PresetStoreError.invalidJSON = error else {
                XCTFail("Expected invalidJSON, got \(error)")
                return
            }
        }
    }

    func test_load_throws_on_unsupported_format_version() throws {
        let url = tempDirectory.appendingPathComponent("future.tnf")
        let json = """
        {
          "formatVersion": 999,
          "name": "future",
          "outputGain": 1.0,
          "nodes": []
        }
        """
        try json.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try PresetStore.load(from: url)) { error in
            guard case PresetStoreError.unsupportedFormatVersion(let version) = error else {
                XCTFail("Expected unsupportedFormatVersion, got \(error)")
                return
            }
            XCTAssertEqual(version, 999)
        }
    }
}
