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
    /// On first run (no baseline) the baseline is written and the test passes;
    /// subsequent runs assert byte-equality.
    static func assertSnapshot<V: View>(
        _ view: V,
        named name: String,
        size: CGSize = CGSize(width: 320, height: 600),
        sourceFile: StaticString = #filePath,
        file: StaticString = #file,
        line: UInt = #line
    ) throws {
        guard let pngData = render(view, size: size) else {
            XCTFail("Failed to render view to PNG", file: file, line: line)
            return
        }

        let baselineURL = baselineDirectory(sourceFile: sourceFile).appendingPathComponent("\(name).png")

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
                "If this is a deliberate visual change, delete the baseline and re-run.",
                file: file, line: line
            )
        } else {
            // First run: write the baseline. Test passes on this run; future
            // runs assert against it.
            try FileManager.default.createDirectory(
                at: baselineURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try pngData.write(to: baselineURL)
        }
    }

    /// Render `view` to PNG bytes at `size`.
    private static func render<V: View>(_ view: V, size: CGSize) -> Data? {
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
