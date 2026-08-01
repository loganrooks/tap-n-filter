import AVFoundation
import Capture
import Combine
import Effects
import Graph
import SwiftUI
@testable import UI
@testable import ViewModel
import XCTest

/// Layout-contract guard for the macOS-27 panel-collapse regression.
///
/// WHY THIS EXISTS
///
/// On macOS 27, the `MenuBarExtra(.window)` panel collapsed and the effect
/// list vanished. Root cause: `ChainEditorView`'s `ScrollView` had only a
/// `.frame(maxHeight:)` constraint with no floor. A `ScrollView` reports no
/// intrinsic height; when the window's fitting-size pass ran it resolved the
/// scroll region to zero, collapsing the whole panel. The fix added
/// `.frame(minHeight: 200, maxHeight: 440)` to the scroll region and
/// `.frame(minHeight: 420, maxHeight: 700)` to `ControlPanelView`'s root.
///
/// These tests guard the contract by hosting the view in an
/// `NSHostingController`, pinning its width to 380 pt, and asserting the
/// fitting height stays within the specified floor/cap. They exercise the
/// real SwiftUI layout pass — not a snapshot at a fixed caller-dictated
/// size — so a reintroduced collapse (fitting height -> 0) will fail them.
///
/// IMPORTANT CAVEAT
///
/// This guard catches the collapse on whatever macOS version the test runs
/// on. The macOS-27-specific manifestation requires running on macOS 27
/// (local developer machine or a self-hosted CI runner), because GitHub
/// Actions does not offer a macOS 27 image as of 2026-06. On macOS 26 and
/// earlier the panel does not collapse — the regression is OS-version-
/// specific. Running these tests on any available macOS version still
/// provides a meaningful regression guard: a refactor that removes the
/// `minHeight` floor would fail them everywhere.
@MainActor
final class LayoutContractTests: XCTestCase {

    // MARK: - Empty chain

    /// With no effects in the chain, `ControlPanelView` must still meet the
    /// 420 pt height floor declared in `docs/specs/ui.md`. This is the
    /// exact scenario that collapsed on macOS 27.
    func test_emptyChain_fittingHeight_meetsFloor() async throws {
        let model = try await makeModel()
        let view = ControlPanelView().environmentObject(model)

        let size = SnapshotHelper.intrinsicSize(of: view, width: 380)

        XCTAssertGreaterThanOrEqual(
            size.height,
            420,
            "ControlPanelView fitting height \(size.height) pt is below the 420 pt floor " +
            "(docs/specs/ui.md). This is the macOS-27 collapse contract."
        )
    }

    // MARK: - Populated chain

    /// With several effects added, the panel must remain inside its declared
    /// height contract: at or above the 420 pt floor and at or below the
    /// 700 pt cap. The chain editor's ScrollView should absorb the extra
    /// rows rather than letting the panel grow unbounded.
    func test_populatedChain_fittingHeight_withinContract() async throws {
        let model = try await makeModel()

        // Seed three effects — one of each built-in type — to exercise the
        // chain editor's scroll region with real content.
        model.addEffect(of: "tnf.eq")
        model.addEffect(of: "tnf.gain")
        model.addEffect(of: "tnf.reverb")

        let view = ControlPanelView().environmentObject(model)
        let size = SnapshotHelper.intrinsicSize(of: view, width: 380)

        XCTAssertGreaterThanOrEqual(
            size.height,
            420,
            "ControlPanelView fitting height \(size.height) pt is below the 420 pt floor " +
            "with a three-effect chain (docs/specs/ui.md)."
        )
        XCTAssertLessThanOrEqual(
            size.height,
            700,
            "ControlPanelView fitting height \(size.height) pt exceeds the 700 pt cap " +
            "with a three-effect chain — the chain editor ScrollView should be absorbing " +
            "the extra rows rather than growing the window (docs/specs/ui.md)."
        )
    }

    // MARK: - Drawers

    /// Opening the settings drawer must lift the height cap, exactly as the
    /// debug drawer does.
    ///
    /// The cap was originally gated on `showDebugPanel` alone while both
    /// drawers append a section below the footer. With a populated chain and
    /// settings open, the panel was therefore squeezed against the 700 pt cap
    /// and had to shed height somewhere — the same class of failure as the
    /// macOS-27 collapse this file exists to guard, arrived at through the
    /// cap rather than the floor.
    func test_settingsDrawerOpen_liftsHeightCap() async throws {
        let model = try await makeModel()

        // Enough effects that the chain editor's ScrollView sits at its own
        // 440 pt maximum, so the closed panel is pressed against the 700 pt
        // cap. Without this the test proves nothing: with only a few rows the
        // panel is far below 700, and "open is taller than closed, and under
        // 900" holds just as well under the old debug-panel-only cap. The
        // discriminating assertion is that the open panel exceeds 700 —
        // impossible unless the settings drawer actually lifts the cap.
        for _ in 0 ..< 12 {
            model.addEffect(of: "tnf.eq")
        }

        let closed = SnapshotHelper.intrinsicSize(
            of: ControlPanelView().environmentObject(model),
            width: 380
        )
        XCTAssertLessThanOrEqual(
            closed.height,
            700,
            "Closed panel is \(closed.height) pt, above its own 700 pt cap — the test's " +
            "premise is broken, not just its conclusion."
        )

        model.toggleSettings()
        XCTAssertTrue(model.showSettings, "toggleSettings did not open the drawer")

        let open = SnapshotHelper.intrinsicSize(
            of: ControlPanelView().environmentObject(model),
            width: 380
        )

        XCTAssertGreaterThan(
            open.height,
            700,
            "Panel is \(open.height) pt with the settings drawer open and a full chain " +
            "(closed: \(closed.height) pt). It has not crossed the 700 pt closed-panel cap, " +
            "so the settings section is being absorbed by the cap rather than extending the " +
            "window — the defect this test guards."
        )
        XCTAssertLessThanOrEqual(
            open.height,
            900,
            "Panel height \(open.height) pt with the settings drawer open exceeds the 900 pt " +
            "drawer cap."
        )
    }

    // MARK: - Helpers

    /// Build a view model backed by a minimal mock capture controller and a
    /// fresh isolated `UserDefaults` suite.
    private func makeModel() async throws -> AppViewModel {
        let defaults = UserDefaults(suiteName: "tnf.layout-contract.\(UUID().uuidString)")!
        let capture = LayoutMockCapture()
        return AppViewModel(
            capture: capture,
            engine: AVAudioEngine(),
            registry: EffectNodeRegistry(),
            defaults: defaults
        )
    }
}

/// Minimal capture-controller stub for layout tests.
///
/// Declared here rather than in a shared helper because SPM scopes test
/// helpers to the file they are declared in — a `private` type in
/// `ControlPanelViewSnapshotTests.swift` is invisible here. The required
/// surface is small enough that the duplication costs less than an
/// `internal` shared file would.
private final class LayoutMockCapture: CaptureControllerProtocol, @unchecked Sendable {
    private let subject = CurrentValueSubject<CaptureState, Never>(.idle)

    var state: CaptureState { subject.value }
    var statePublisher: AnyPublisher<CaptureState, Never> { subject.eraseToAnyPublisher() }
    var captureSourceNode: AVAudioSourceNode? { nil }

    func availableSources() throws -> [CaptureSource] { [] }
    func start(source: CaptureSource, into engine: AVAudioEngine) throws {}
    func stop() throws {}
}
