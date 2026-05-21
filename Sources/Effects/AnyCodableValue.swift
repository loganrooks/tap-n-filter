import Foundation

/// A tagged union over the small set of primitive JSON-encodable values used
/// by `EffectState.extras`.
///
/// `extras` exists for type-specific state that doesn't fit the `parameters`
/// dictionary (which is `[String: Float]`). The reverb's preset enum is the
/// motivating example — it's logically categorical, not numeric, so it lives
/// in `extras` as a `.string`.
///
/// Only the four cases the V1 effects actually use are supported. If a future
/// effect needs nested arrays or dictionaries, this enum gains more cases.
public enum AnyCodableValue: Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
}

extension AnyCodableValue: Codable {

    /// Decode from a JSON primitive.
    ///
    /// Bool is tried first because some Swift JSON toolchains decode `true` as
    /// `Int` 1 when the bool branch is skipped.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Order matters: try bool before numeric types because Swift's JSON
        // decoder will happily read `true` as Int 1 on some toolchains.
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
            return
        }
        if let value = try? container.decode(Int.self) {
            self = .int(value)
            return
        }
        if let value = try? container.decode(Double.self) {
            self = .double(value)
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "AnyCodableValue expected string, int, double, or bool"
        )
    }

    /// Encode as a JSON primitive using the concrete case's underlying type.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        }
    }
}
