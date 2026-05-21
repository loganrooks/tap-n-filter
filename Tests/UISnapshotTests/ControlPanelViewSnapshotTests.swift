import AVFoundation
import Capture
import Combine
import CoreAudio
import Darwin
import Effects
import Foundation
import Graph
import SwiftUI
@testable import UI
@testable import ViewModel
import XCTest

/// Snapshot tests for `ControlPanelView` in three states: idle, running,
/// failed. Baselines are stored under `Tests/UISnapshotTests/__Snapshots__/`
/// and committed alongside the test code per the Phase 3 spec.
@MainActor
final class ControlPanelViewSnapshotTests: XCTestCase {

    func test_snapshot_idle() throws {
        let model = makeModel(state: .idle)
        let view = ControlPanelView()
            .environmentObject(model)
        try SnapshotHelper.assertSnapshot(view, named: "control-panel-idle")
    }

    func test_snapshot_running() throws {
        let source = CaptureSource(
            pid: 1234,
            audioProcessID: 42,
            bundleIdentifier: "com.example.test",
            displayName: "Test App"
        )
        let model = makeModel(state: .running(source: source), currentSource: source)
        let view = ControlPanelView()
            .environmentObject(model)
        try SnapshotHelper.assertSnapshot(view, named: "control-panel-running")
    }

    func test_snapshot_failed() throws {
        let model = makeModel(state: .failed(.permissionDenied))
        let view = ControlPanelView()
            .environmentObject(model)
        try SnapshotHelper.assertSnapshot(view, named: "control-panel-failed")
    }

    // MARK: Helpers

    private func makeModel(
        state: CaptureState,
        currentSource: CaptureSource? = nil
    ) -> AppViewModel {
        let defaults = UserDefaults(suiteName: "tnf.snapshot.\(UUID().uuidString)")!
        let capture = SnapshotMockCapture(initialState: state)
        let model = AppViewModel(
            capture: capture,
            engine: AVAudioEngine(),
            registry: EffectNodeRegistry(),
            defaults: defaults
        )
        if let currentSource {
            model.currentSource = currentSource
        }
        return model
    }
}

/// Snapshot-only mock; identical surface to the ViewModelTests mock but
/// duplicated here because SPM scopes test-target helpers to a single target.
private final class SnapshotMockCapture: CaptureControllerProtocol, @unchecked Sendable {
    private let subject: CurrentValueSubject<CaptureState, Never>
    var state: CaptureState { subject.value }
    var statePublisher: AnyPublisher<CaptureState, Never> { subject.eraseToAnyPublisher() }

    init(initialState: CaptureState) {
        self.subject = CurrentValueSubject(initialState)
    }

    func availableSources() throws -> [CaptureSource] { [] }
    func start(source: CaptureSource, into engine: AVAudioEngine) throws {}
    func stop() throws {}
}
