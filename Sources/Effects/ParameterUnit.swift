import Foundation

/// The unit in which an `EffectParameter`'s value is expressed.
///
/// The unit informs how UI surfaces format and edit the value (Hz vs dB vs
/// percent vs raw integer) and how documentation describes the parameter's
/// range. It does not affect the underlying numeric type — every parameter
/// stores `Float` regardless.
///
/// See `docs/specs/effect-node-protocol.md` for the canonical list.
public enum ParameterUnit: Equatable {
    case hertz
    case decibels
    case ratio
    case seconds
    case milliseconds
    case normalized
    case percent
    case integer
    case enumValue(cases: [String])
}
