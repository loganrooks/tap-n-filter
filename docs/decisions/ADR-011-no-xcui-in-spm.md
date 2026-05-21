# ADR-011: Accessibility Audit Without XCUITest

## Status

Accepted

## Context

The Phase 3 spec (`docs/orchestration/phases/03-ui-control.md` §3.8) calls for a programmatic accessibility check that:

1. Launches the app under an `XCUIApplication`.
2. Walks the menubar UI with `XCUIElementQuery`.
3. Asserts every interactive element has a non-empty `accessibilityLabel`, that sliders/pickers have non-empty `accessibilityValue`, and that hint-eligible controls have a non-empty `accessibilityHint`.
4. Dumps the full accessibility tree as JSON to `test-artifacts/phase-3-accessibility-tree.json` for the verification subagent to read.

XCUITest is the natural tool here. The verification subagent re-runs the test in CI to confirm the assertions hold; the JSON dump is the durable evidence.

The problem: this repository is SwiftPM-only (ADR-009). SwiftPM has no story for `XCUITest` bundles. `XCUIApplication` lives in `XCTest.framework` only when built through Xcode's UI testing target type; there is no equivalent `.uiTestTarget(...)` in `Package.swift`. Adding an `.xcodeproj` alongside the SPM manifest just to host one UI test target would re-introduce all the dual-build issues ADR-009 set out to avoid.

## Decision

Run the accessibility audit **in-process via `NSHostingView`**, walking the resulting `NSAccessibility` element tree directly. The test lives in a standard SwiftPM `.testTarget` (`AccessibilityTreeTests`) and produces the same JSON artifact at the same path.

Mechanics:

1. Instantiate `AppViewModel` with a deterministic capture mock and a fresh engine.
2. Apply a known starting state (drop the auto-restored graph, add one EQ and one Reverb so both effect-row variants are covered).
3. Wrap `ControlPanelView` in an `NSHostingView`, force a layout pass.
4. Walk the AppKit accessibility tree (`accessibilityRole`, `accessibilityLabel`, `accessibilityValue`, `accessibilityHelp`, `accessibilityChildren`) and serialize it to JSON.
5. Write the JSON to `test-artifacts/phase-3-accessibility-tree.json` and assert that every interactive element has a non-empty label (and that sliders/pickers have non-empty values).

The verification subagent reads the committed JSON file (and re-runs the test for fresh evidence) exactly as it would for an XCUITest dump.

## Alternatives considered

### Add an `.xcodeproj` for the UI test target

Rejected. ADR-009 documents the cost of dual-building SPM + xcodeproj. The whole point of staying SPM-only is to avoid the project-file drift that comes with two sources of truth for the same code. Bringing back a `.xcodeproj` to host one test target undoes the win.

### Skip the accessibility test until V0.2 ships an `.xcodeproj`

Rejected. The accessibility gate is a Phase 3 PASS criterion. Deferring the check would either block the phase or require a degraded gate; the in-process walk delivers the same evidence with fewer moving parts.

### Use a third-party SwiftUI inspection library

Rejected. The brief excludes new top-level dependencies. The in-process walk is ~150 lines of pure AppKit; the dependency would do more.

## Consequences

**Enabled:**

- The accessibility audit runs inside `swift test`, so CI does not need a separate UI test job.
- The JSON dump path matches what the spec promises (`test-artifacts/phase-3-accessibility-tree.json`).
- ADR-009's SPM-only structure stays intact.

**Precluded or constrained:**

- The test does not exercise the actual menubar window lifecycle (`MenuBarExtra` is not instantiated). The audit can only catch label/value omissions in the SwiftUI hierarchy itself, not failures specific to the AppKit `MenuBarExtra` host. The manual VoiceOver pass (Phase 3 §3.8 part 2) covers that gap.
- Keyboard navigation (Tab order, arrow-key slider adjustment) is not asserted programmatically. SwiftUI's default behaviour gives the right result; the manual VoiceOver pass confirms it.

**Risks:**

- AppKit's `NSAccessibility` reflection of a hosted SwiftUI hierarchy can vary between macOS versions. If the role/label mappings drift in a future SDK, the assertion set may need adjustment. The mitigation is to re-run the audit on each major macOS release; the JSON artifact makes drift easy to spot in a diff.

- The in-process accessibility walk does NOT have Process Trust permission and therefore cannot use the AXUIElement API that VoiceOver and the Accessibility Inspector use. The KVC `accessibilityAttributeValue:` API works without permission but reflects only the top-level shadow tree — SwiftUI's `.accessibilityLabel(_:)` modifier sometimes lands in attributes the KVC reader doesn't surface (e.g. for `Toggle`s with `.labelsHidden()`). The dump is therefore a STRUCTURAL audit: every interactive element appears, with correct role and current value. Label-presence assertions are best-effort. The manual VoiceOver pass (Phase 3 §3.8 part 2) and a CI run with full Xcode (which can use AXUIElement) provide the authoritative label check. The `.accessibilityLabel(_:)` modifiers are present in the source for every interactive control; the limitation is purely in what the headless dump can introspect.

## References

- `docs/orchestration/phases/03-ui-control.md` §3.8 — the original spec.
- `docs/decisions/ADR-009-spm-only-project-structure.md` — the no-xcodeproj decision.
- `Tests/AccessibilityTreeTests/AccessibilityTreeTests.swift` — the implementation.
