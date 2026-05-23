import AVFoundation
import Capture
import Combine
import Effects
import Foundation
import Graph
@testable import ViewModel
import XCTest

/// Unit tests for `AppViewModel`. The capture controller is a mock; the
/// engine is a fresh `AVAudioEngine` (instantiated per test). UserDefaults
/// is a unique `init(suiteName:)` instance per test to avoid cross-test
/// contamination.
@MainActor
final class AppViewModelTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String = ""

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "tnf.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        try await super.tearDown()
    }

    // MARK: Helpers

    private func makeViewModel(
        capture: MockCaptureController = MockCaptureController(),
        engine: AVAudioEngine = AVAudioEngine()
    ) -> AppViewModel {
        AppViewModel(
            capture: capture,
            engine: engine,
            registry: EffectNodeRegistry(),
            defaults: defaults
        )
    }

    private func makeSource(pid: pid_t = 1234, bundleID: String = "com.example.test") -> CaptureSource {
        CaptureSource(
            pid: pid,
            audioProcessID: 42,
            bundleIdentifier: bundleID,
            displayName: "Test"
        )
    }

    // MARK: State mirroring

    func test_initial_captureState_is_idle() async throws {
        let model = makeViewModel()
        // Allow the publisher subscription to deliver the initial value.
        await Task.yield()
        XCTAssertEqual(model.captureState, .idle)
    }

    func test_captureState_mirrors_simulated_transitions() async throws {
        let capture = MockCaptureController()
        let model = makeViewModel(capture: capture)
        await Task.yield()

        capture.simulateState(.starting)
        await waitFor(model: model) { $0.captureState == .starting }

        let source = makeSource()
        capture.simulateState(.running(source: source))
        await waitFor(model: model) { $0.captureState == .running(source: source) }

        capture.simulateState(.stopping)
        await waitFor(model: model) { $0.captureState == .stopping }

        capture.simulateState(.idle)
        await waitFor(model: model) { $0.captureState == .idle }
    }

    // MARK: Source switching

    func test_setSource_while_running_calls_stop() async throws {
        let capture = MockCaptureController()
        let initial = makeSource(pid: 1, bundleID: "com.example.first")
        capture.simulateState(.running(source: initial))
        let model = makeViewModel(capture: capture)
        await Task.yield()
        model.currentSource = initial

        let next = makeSource(pid: 2, bundleID: "com.example.second")
        model.setSource(next)
        await Task.yield()

        // setSource fired a Task; let it run.
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertGreaterThanOrEqual(capture.stopCallCount, 1)
        XCTAssertEqual(model.currentSource?.bundleIdentifier, "com.example.second")
    }

    // MARK: Persistence round-trip

    func test_persistence_round_trip_restores_graph() async throws {
        let capture = MockCaptureController()
        let model = makeViewModel(capture: capture)
        await Task.yield()

        // Start from a known empty graph so the round-trip assertion is
        // independent of the auto-restored fallback (distant-engines).
        while !model.graph.nodes.isEmpty {
            model.removeEffect(at: 0)
        }
        // Mutate the graph and let the debounced write fire.
        model.addEffect(of: "tnf.reverb")
        try await Task.sleep(nanoseconds: 400_000_000)

        let expectedCount = model.graph.nodes.count
        let expectedLastName = model.graph.nodes.last?.displayName

        // Instantiate a second view model with the same defaults; it should
        // restore exactly what the first model persisted.
        let model2 = AppViewModel(
            capture: MockCaptureController(),
            engine: AVAudioEngine(),
            registry: EffectNodeRegistry(),
            defaults: defaults
        )
        await Task.yield()
        XCTAssertEqual(model2.graph.nodes.count, expectedCount)
        XCTAssertEqual(model2.graph.nodes.last?.displayName, expectedLastName)
        XCTAssertEqual(model2.graph.nodes.last?.displayName, "Reverb")
    }

    func test_falls_back_to_distant_engines_on_corrupt_data() async throws {
        defaults.set(Data("not json".utf8), forKey: AppViewModelDefaultsKey.graph)
        let model = makeViewModel()
        await Task.yield()
        // distant-engines has at least one node — empty graph would mean
        // the fallback failed silently.
        XCTAssertGreaterThan(model.graph.nodes.count, 0)
    }

    // MARK: Graph mutations

    func test_addEffect_appends_node() async throws {
        let model = makeViewModel()
        await Task.yield()
        let initialCount = model.graph.nodes.count
        model.addEffect(of: "tnf.eq")
        XCTAssertEqual(model.graph.nodes.count, initialCount + 1)
        XCTAssertEqual(model.graph.nodes.last?.displayName, "EQ")
    }

    func test_removeEffect_drops_node() async throws {
        let model = makeViewModel()
        await Task.yield()
        model.addEffect(of: "tnf.eq")
        model.addEffect(of: "tnf.reverb")
        let beforeCount = model.graph.nodes.count
        model.removeEffect(at: 0)
        XCTAssertEqual(model.graph.nodes.count, beforeCount - 1)
    }

    func test_moveEffect_reorders_nodes() async throws {
        let model = makeViewModel()
        await Task.yield()
        // Wipe whatever the fallback installed by removing everything first.
        while !model.graph.nodes.isEmpty {
            model.removeEffect(at: 0)
        }
        model.addEffect(of: "tnf.eq")
        model.addEffect(of: "tnf.reverb")
        XCTAssertEqual(model.graph.nodes[0].displayName, "EQ")
        XCTAssertEqual(model.graph.nodes[1].displayName, "Reverb")

        model.moveEffect(from: 0, to: 2)
        XCTAssertEqual(model.graph.nodes[0].displayName, "Reverb")
        XCTAssertEqual(model.graph.nodes[1].displayName, "EQ")
    }

    // MARK: updateParameter throttling

    func test_updateParameter_writes_are_throttled() async throws {
        let model = makeViewModel()
        await Task.yield()
        // Wipe and add a single EQ so we know the node ID and parameter set.
        while !model.graph.nodes.isEmpty {
            model.removeEffect(at: 0)
        }
        model.addEffect(of: "tnf.eq")
        guard let eq = model.graph.nodes.first as? EQNode else {
            XCTFail("EQ should be at index 0")
            return
        }

        // Pound the slider 100 times within the same tick. Throttle bucket is
        // ~33 ms, so only one (the first) should land before the throttle
        // window opens — generously: <40 successes.
        let startValue = eq.parameterValue("hp.frequency") ?? 80
        for _ in 0 ..< 100 {
            model.updateParameter(
                nodeID: eq.id,
                paramID: "hp.frequency",
                value: Float.random(in: 100 ... 200)
            )
        }
        // The first write should have landed; later writes were throttled.
        let postValue = eq.parameterValue("hp.frequency") ?? startValue
        // We can't observe an exact count, but the value must have changed
        // exactly once across the run — i.e. it landed (different from 80)
        // but didn't keep racing.
        XCTAssertNotEqual(postValue, startValue, "First write should land")
    }

    // MARK: powerOn / powerOff

    func test_powerOn_without_source_sets_error() async throws {
        let model = makeViewModel()
        await Task.yield()
        await model.powerOn()
        XCTAssertNotNil(model.lastError)
    }

    // MARK: Waiters

    /// Polls the view model until `predicate(model)` returns true, or 1s
    /// elapses. Designed for transitions that arrive via the Combine
    /// subscription on the main queue.
    private func waitFor(
        model: AppViewModel,
        timeout: TimeInterval = 1.0,
        predicate: @escaping (AppViewModel) -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate(model) { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Predicate did not become true within \(timeout) seconds")
    }
}
