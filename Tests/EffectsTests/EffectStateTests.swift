import Foundation
import XCTest
@testable import Effects

final class EffectStateTests: XCTestCase {

    func test_effect_state_round_trips_through_JSON() throws {
        let state = EffectState(
            typeIdentifier: "tnf.eq",
            id: UUID(uuidString: "2EF8A6F0-1234-5678-9ABC-DEF012345678")!,
            displayName: "EQ",
            bypass: false,
            wetDryMix: 1.0,
            parameters: [
                "hp.frequency": 80.0,
                "hp.Q": 0.707,
                "lp.frequency": 800.0,
                "lp.Q": 1.2
            ],
            extras: [
                "reverbName": .string("largeHall"),
                "delayMs": .int(120),
                "feedback": .double(0.42),
                "limiterOn": .bool(true)
            ]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        let decoded = try JSONDecoder().decode(EffectState.self, from: data)

        XCTAssertEqual(decoded, state)
    }

    func test_any_codable_value_decodes_each_primitive_type() throws {
        let cases: [(json: String, expected: AnyCodableValue)] = [
            ("\"hello\"", .string("hello")),
            ("42", .int(42)),
            ("3.14", .double(3.14)),
            ("true", .bool(true))
        ]
        for (json, expected) in cases {
            let data = Data(json.utf8)
            let decoded = try JSONDecoder().decode(AnyCodableValue.self, from: data)
            XCTAssertEqual(decoded, expected, "failed for \(json)")
        }
    }
}
