import AVFoundation
import AppKit
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

/// Programmatic accessibility audit for the Phase 3 control panel.
///
/// SwiftPM does not support XCUI test bundles (see ADR-011), so the audit is
/// run in-process: render `ControlPanelView` via `NSHostingView`, walk the
/// resulting AppKit accessibility tree, and serialize it to
/// `test-artifacts/phase-3-accessibility-tree.json`. The walk also asserts
/// that every interactive element has a non-empty accessibility label and
/// that sliders/pickers have non-empty accessibility values.
@MainActor
final class AccessibilityTreeTests: XCTestCase {

    func test_dump_accessibility_tree() throws {
        // Use a deterministic view model: empty graph (so the dump is stable),
        // no source, idle state.
        let defaults = UserDefaults(suiteName: "tnf.a11y.\(UUID().uuidString)")!
        let capture = StubCaptureController()
        let model = AppViewModel(
            capture: capture,
            engine: AVAudioEngine(),
            registry: EffectNodeRegistry(),
            defaults: defaults
        )
        // Drop the auto-restored graph so the dump is small and stable.
        while !model.graph.nodes.isEmpty {
            model.removeEffect(at: 0)
        }
        // Add one EQ and one Reverb so the dump exercises both effect-row
        // variants (EQ hides wet/dry in header per ADR-007).
        model.addEffect(of: "tnf.eq")
        model.addEffect(of: "tnf.reverb")

        let root = ControlPanelView().environmentObject(model)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: 320, height: 600)
        // Force a layout pass so accessibility children are populated.
        hosting.layoutSubtreeIfNeeded()

        let dump = AccessibilityNode.dump(from: hosting)
        let data = try JSONEncoder.pretty.encode(dump)
        let url = artifactsURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)

        // Assertions: every interactive element must have a label; sliders
        // and pickers must have non-empty values.
        let interactive = dump.flattened().filter { $0.isInteractive }
        XCTAssertFalse(interactive.isEmpty, "Expected at least one interactive element in the dump.")
        for node in interactive {
            XCTAssertFalse(
                (node.label ?? "").isEmpty,
                "Interactive element \(node.role ?? "?") has empty accessibilityLabel"
            )
            if node.role == "AXSlider" || node.role == "AXPopUpButton" {
                XCTAssertFalse(
                    (node.value ?? "").isEmpty,
                    "Slider/Picker \(node.label ?? "?") has empty accessibilityValue"
                )
            }
        }
    }

    /// Resolve the on-disk path the verification subagent will read. Walks
    /// up from `__FILE__` to the repo root.
    private func artifactsURL() -> URL {
        // The current working directory when SwiftPM runs tests is the
        // package root.
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("test-artifacts/phase-3-accessibility-tree.json")
    }
}

/// Serializable node in the accessibility-tree dump. Mirrors the small set of
/// NSAccessibility properties we care about for the audit.
private struct AccessibilityNode: Codable {
    let role: String?
    let label: String?
    let value: String?
    let help: String?
    let identifier: String?
    let children: [AccessibilityNode]

    /// Whether this node represents something the user can interact with.
    /// AppKit reports a wide variety of roles; we treat the documented
    /// interactive set as interactive and ignore static text / group nodes.
    var isInteractive: Bool {
        switch role {
        case "AXButton", "AXSlider", "AXCheckBox", "AXPopUpButton",
             "AXMenuButton", "AXTextField", "AXIncrementor", "AXStepper",
             "AXSwitch", "AXRadioButton":
            return true
        default:
            return false
        }
    }

    /// Recursive walk producing a flat list of every node in subtree order.
    func flattened() -> [AccessibilityNode] {
        var result: [AccessibilityNode] = [self]
        for child in children {
            result.append(contentsOf: child.flattened())
        }
        return result
    }

    /// Build an `AccessibilityNode` from any `NSAccessibility` element.
    static func dump(from element: Any) -> AccessibilityNode {
        let role = (element as AnyObject).accessibilityRole()?.rawValue
        let label = (element as AnyObject).accessibilityLabel?()
        let value = stringify((element as AnyObject).accessibilityValue?())
        let help = (element as AnyObject).accessibilityHelp?()
        let identifier = (element as AnyObject).accessibilityIdentifier?()
        let rawChildren = (element as AnyObject).accessibilityChildren?() ?? []
        let children = rawChildren.compactMap { child -> AccessibilityNode? in
            return AccessibilityNode.dump(from: child as Any)
        }
        return AccessibilityNode(
            role: role,
            label: label,
            value: value,
            help: help,
            identifier: identifier,
            children: children
        )
    }

    /// AppKit returns `Any?` for accessibilityValue; coerce to a String.
    private static func stringify(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        if let bool = value as? Bool { return bool ? "true" : "false" }
        return String(describing: value)
    }
}

/// Minimal stub of `CaptureControllerProtocol` used only to instantiate the
/// view model; this target does not depend on the ViewModel tests target.
private final class StubCaptureController: CaptureControllerProtocol, @unchecked Sendable {
    private let subject = CurrentValueSubject<CaptureState, Never>(.idle)
    var state: CaptureState { subject.value }
    var statePublisher: AnyPublisher<CaptureState, Never> { subject.eraseToAnyPublisher() }

    func availableSources() throws -> [CaptureSource] { [] }
    func start(source: CaptureSource, into engine: AVAudioEngine) throws {}
    func stop() throws {}
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
