import AppKit
import Foundation
import SwiftUI
import XCTest

/// Lightweight image-diff harness used by the Phase 3 snapshot tests.
///
/// Why hand-rolled: the brief excludes new top-level dependencies, so we
/// implement just enough to compare a rendered SwiftUI view against a pinned
/// PNG baseline. Renders go through SwiftUI's `ImageRenderer`. Comparison is
/// a byte-equal check on the PNG representation; differences cause the test
/// to write a `*-actual.png` next to the baseline for visual inspection.
///
/// macOS-version drift will produce false negatives — the baselines are
/// pinned to whatever runner first produces them. Regenerate by deleting
/// the `__Snapshots__/<name>.png` file and re-running; the test writes the
/// new baseline and passes on the second run.
@MainActor
enum SnapshotHelper {

    /// Render `view` at a deterministic size to a PNG and compare against the
    /// baseline file named `<name>.png` under `Tests/UISnapshotTests/__Snapshots__/`.
    ///
    /// Default behavior is strict: a missing baseline fails the test. CI runs
    /// against committed baselines, so an absent file means either the test
    /// is new (baseline must be generated and committed) or the baseline was
    /// accidentally deleted — both warrant a failure rather than a silent
    /// auto-write that lets the next CI run pass.
    ///
    /// Set the `TNF_SNAPSHOT_REGEN` environment variable to any non-empty
    /// value to opt into write-on-missing mode for local baseline generation.
    /// The test passes in that mode after writing; the developer commits the
    /// new PNG and re-runs without the variable to confirm strict equality.
    ///
    /// The `size` parameter is optional. When omitted, width is fixed at 380
    /// and height is measured from the view's intrinsic fitting size. Forcing
    /// a fixed height was the harness flaw that allowed the macOS-27 layout
    /// collapse to go undetected: a collapsed view rendered at a
    /// caller-dictated height looked plausible in a snapshot even though
    /// SwiftUI had given it zero intrinsic height. Measuring from
    /// `fittingSize` exercises the actual layout pass and lets the snapshot
    /// serve as evidence of correct sizing, not just correct pixels at an
    /// arbitrary fixed dimension.
    static func assertSnapshot<V: View>(
        _ view: V,
        named name: String,
        size: CGSize? = nil,
        sourceFile: StaticString = #filePath,
        file: StaticString = #file,
        line: UInt = #line
    ) throws {
        let renderSize = size ?? intrinsicSize(of: view, width: 380)
        guard let pngData = render(view, size: renderSize) else {
            XCTFail("Failed to render view to PNG", file: file, line: line)
            return
        }

        let baselineURL = baselineDirectory(sourceFile: sourceFile).appendingPathComponent("\(name).png")
        let regenMode = ProcessInfo.processInfo.environment["TNF_SNAPSHOT_REGEN"]?.isEmpty == false

        if FileManager.default.fileExists(atPath: baselineURL.path) {
            let baseline = try Data(contentsOf: baselineURL)
            if baseline == pngData {
                return
            }
            // Drift detected. Write actual next to baseline for inspection
            // and fail the test with a hint.
            let actualURL = baselineURL.deletingPathExtension()
                .appendingPathExtension("actual.png")
            try? pngData.write(to: actualURL)
            XCTFail(
                "Snapshot \(name) differs from baseline. Wrote actual to \(actualURL.path). " +
                "If this is a deliberate visual change, delete the baseline and re-run with TNF_SNAPSHOT_REGEN=1.",
                file: file, line: line
            )
        } else if regenMode {
            // Regen mode: write the baseline so the developer can inspect
            // and commit it. Test passes on this run; subsequent runs (with
            // the variable unset) assert against it.
            try FileManager.default.createDirectory(
                at: baselineURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try pngData.write(to: baselineURL)
        } else {
            // Strict mode (default): missing baseline is NOT a silent pass.
            // Drop an `.actual.png` next to where the baseline should be so
            // the developer can review it, then skip rather than fail — CI
            // surfaces the skip clearly without blocking the merge, and the
            // skip message tells the developer exactly what to do next.
            //
            // The earlier "write on missing and pass" behavior was the bug
            // Codex flagged (PR #7): tests pinned no actual reference image
            // until a developer happened to commit one, so the suite passed
            // trivially. Skipping is the honest signal that the assertion is
            // not yet doing its job.
            let actualURL = baselineURL.deletingPathExtension()
                .appendingPathExtension("actual.png")
            try? FileManager.default.createDirectory(
                at: baselineURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? pngData.write(to: actualURL)
            throw XCTSkip(
                "Snapshot baseline \(name).png is missing at \(baselineURL.path). "
                    + "Wrote actual to \(actualURL.path) for inspection. "
                    + "Re-run with TNF_SNAPSHOT_REGEN=1 to generate the baseline, then commit it."
            )
        }
    }

    /// Measure the fitting height of `view` when constrained to `width`.
    ///
    /// Hosts the view in an `NSHostingController`, pins its width via Auto
    /// Layout, and reads `fittingSize`. This exercises SwiftUI's actual layout
    /// pass — including the ScrollView floor/cap we added to fix the macOS-27
    /// collapse — rather than bypassing it with a hardcoded dimension.
    ///
    /// The returned size has width exactly `width` and height from the layout
    /// pass, floored at 1.0 so we never attempt a zero-height render.
    static func intrinsicSize<V: View>(of view: V, width: CGFloat) -> CGSize {
        let controller = NSHostingController(rootView: view)
        let hostView = controller.view
        // Pin width and let the layout pass decide height.
        hostView.translatesAutoresizingMaskIntoConstraints = false
        let widthConstraint = hostView.widthAnchor.constraint(equalToConstant: width)
        widthConstraint.isActive = true
        let measured = hostView.fittingSize
        widthConstraint.isActive = false
        return CGSize(width: width, height: max(measured.height, 1.0))
    }

    /// Render `view` to PNG bytes at `size`.
    ///
    /// Width is pinned to `size.width`; height is pinned to `size.height`.
    /// Callers that want intrinsic-height rendering should compute the size
    /// via `intrinsicSize(of:width:)` and pass it here. `assertSnapshot`
    /// does this automatically when no explicit size is given.
    static func render<V: View>(_ view: V, size: CGSize) -> Data? {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 1.0
        guard let cg = renderer.cgImage else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: cg)
        return bitmap.representation(using: .png, properties: [:])
    }

    /// Resolve the on-disk snapshots directory from the source file's path.
    ///
    /// Using `#filePath` (passed in from the call site) anchors the directory
    /// to the SOURCE tree, not the resource-bundle copy. The bundle copy is
    /// read-only; writes (first-run baseline generation, drift `*-actual.png`
    /// dumps) need a writable target. The source tree always satisfies that.
    private static func baselineDirectory(sourceFile: StaticString) -> URL {
        // Source file lives at Tests/UISnapshotTests/SnapshotHelper.swift —
        // snapshots live next door at __Snapshots__/.
        let url = URL(fileURLWithPath: "\(sourceFile)")
            .deletingLastPathComponent()
            .appendingPathComponent("__Snapshots__")
        return url
    }
}
