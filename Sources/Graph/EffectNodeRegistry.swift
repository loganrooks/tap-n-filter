import Effects
import Foundation

/// Errors raised by `EffectNodeRegistry`.
public enum RegistryError: Error, Equatable {
    case unknownTypeIdentifier(String)
    case duplicateRegistration(String)
}

/// Maps `EffectNode.typeIdentifier` strings to factory closures.
///
/// The registry is the single point where the app enumerates known effect
/// types. Adding a new effect means registering it here (typically in
/// `init` for built-ins, or at app launch for plugins).
///
/// V1 ships two built-in types — `EQNode` and `ReverbNode` — both registered
/// by `init`. The singleton `shared` is the default registry used by
/// `Graph.restore`. Tests may construct their own registries.
public final class EffectNodeRegistry {

    public typealias Factory = () -> any EffectNode

    private var factories: [String: Factory] = [:]
    private let queue = DispatchQueue(
        label: "tap-n-filter.EffectNodeRegistry",
        attributes: .concurrent
    )

    public static let shared: EffectNodeRegistry = .init()

    /// Construct a registry with the V1 built-in effects already registered.
    public init() {
        register(EQNode.self)
        register(ReverbNode.self)
    }

    /// Register a new effect type. The type must be default-constructible —
    /// the factory invokes the no-argument initializer. Subsequent registrations
    /// of the same `typeIdentifier` overwrite the previous factory (useful in
    /// tests; in production each identifier is registered exactly once).
    public func register<T: EffectNode>(_ type: T.Type) where T: DefaultConstructibleEffectNode {
        queue.async(flags: .barrier) { [weak self] in
            self?.factories[T.typeIdentifier] = { T.init() }
        }
    }

    /// Create a fresh node for the given identifier. The node is in its
    /// default state; the caller is expected to immediately call
    /// `restore(from:)` if loading from a preset.
    public func makeNode(typeIdentifier: String) throws -> any EffectNode {
        var resolvedFactory: Factory?
        queue.sync {
            resolvedFactory = factories[typeIdentifier]
        }
        guard let factory = resolvedFactory else {
            throw RegistryError.unknownTypeIdentifier(typeIdentifier)
        }
        return factory()
    }

    /// All currently-registered type identifiers, sorted for stable output.
    public var registeredTypeIdentifiers: [String] {
        var result: [String] = []
        queue.sync {
            result = factories.keys.sorted()
        }
        return result
    }
}

/// Marker protocol: an `EffectNode` whose initializer can be called with no
/// arguments. The registry needs this so it can construct fresh nodes from a
/// `typeIdentifier` string alone. The built-in effects all conform; future
/// AUv3-style nodes that need extra arguments will register through a
/// separate factory path.
public protocol DefaultConstructibleEffectNode: EffectNode {
    init()
}

extension EQNode: DefaultConstructibleEffectNode {}
extension ReverbNode: DefaultConstructibleEffectNode {}
